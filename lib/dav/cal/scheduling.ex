defmodule Dav.Cal.Scheduling do
  @moduledoc """
  Implicit scheduling — RFC 6638 section 3.

  The difference between a calendar server and a shared filing
  cabinet. When an organiser stores an event naming attendees, the
  server delivers the invitation to each of them; when an attendee
  changes their own `PARTSTAT`, the server delivers the reply back to
  the organiser. Neither party posts anything to an Outbox: the
  scheduling is *implicit* in the write.

  Without it, an organiser's calendar shows a meeting with five
  attendees and none of them has heard about it — a failure that looks
  like success, which is why the specification makes this the server's
  job rather than the client's.

  ### Which way the message goes

  The direction is decided by who owns the calendar being written to:

  * the **organiser's** copy, so the message is a `REQUEST` to every
    attendee other than the organiser themselves ("the server MUST NOT
    send a scheduling message to the Attendee that matches the
    Organizer");

  * an **attendee's** copy, so the message is a `REPLY` to the
    organiser alone.

  ### Failures are recorded, not raised

  A hook cannot fail the write that triggered it, and should not: an
  attendee whose server is unreachable is not a reason to refuse the
  organiser's own event. Delivery that does not happen simply does not
  happen, and the organiser learns from the absence of a reply.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.FreeBusy
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  # RFC 5546 section 2.1.4: an organiser making a change that affects
  # what attendees agreed to must raise `SEQUENCE`, and their clients
  # use it to tell a re-invitation from a duplicate. A change to a
  # description or an alarm is not one of those; a change to when or
  # where it happens is.
  # The type the suite expects a stored calendar object to report,
  # parameter included: a client that asked for `charset=utf-8` on the
  # way in is entitled to see it on the way out.
  @calendar_type "text/calendar;charset=utf-8"

  @significant ~w(DTSTART DTEND DURATION DUE RRULE RDATE EXDATE LOCATION STATUS)

  # When the meeting itself moves. A narrower list than `@significant`:
  # an event being called off, or moving down the corridor, is news the
  # attendees need without being asked to answer for it again.
  @rescheduled ~w(DTSTART DTEND DURATION DUE RRULE RDATE)

  # Properties every save rewrites, and parameters the server owns.
  # Neither is news to an attendee, so neither counts as a reason to
  # send them a message.
  @bookkeeping ~w(DTSTAMP LAST-MODIFIED CREATED SEQUENCE)
  @maintained ~w(SCHEDULE-STATUS SCHEDULE-AGENT RSVP)

  # The `X-` names that belong to the event rather than to one
  # person's copy of it, and so travel with a scheduling message. A
  # deployment says which those are — the set is a matter of local
  # agreement between clients, not of the specification — and this is
  # the default for one that says nothing.
  @public ~w(X-APPLE-STRUCTURED-LOCATION)
  @doc """
  Whether this hook applies — only inside a calendar collection.

  ### Arguments

  * `collection` is the parent collection, or `nil`.

  ### Returns

  * `true` for a calendar collection.

  ### Examples

      iex> Dav.Cal.Scheduling.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.Scheduling.applies?(nil)
      false

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  The `Schedule-Tag` of a scheduling object resource.

  RFC 6638 section 8.2. Only a *scheduling* object has one — an event
  with an organiser and attendees — and its value tracks the
  scheduling content rather than the resource: an attendee editing
  their own alarm changes the ETag and must not change this.

  This server keeps them in step, which is correct but conservative:
  a client will resynchronise a little more often than it needs to.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A `Schedule-Tag` header when the resource is a scheduling object,
    and nothing otherwise.

  """
  @impl Dav.Web.Hook
  @spec headers(Resource.t(), Resource.t() | nil, map()) :: [{String.t(), String.t()}]
  def headers(%Resource{collection?: true}, _collection, _options), do: []

  def headers(%Resource{} = resource, _collection, options) do
    case stored_schedule_tag(resource, options) do
      nil -> []
      tag -> [{"schedule-tag", tag}]
    end
  end

  # Every stored scheduling object names people the same way. One
  # person may arrive as `mailto:`, as a bare address, or as a URN
  # depending on the client, and a copy that keeps whichever spelling
  # it was given cannot be compared with any other copy — an
  # attendee's reply stops matching the invitation it answers. The
  # rewrite happens only when it would change something, so an object
  # already in canonical form costs one comparison and no write.
  defp normalised(resource, calendar, options) do
    canonical = %{calendar | components: Enum.map(calendar.components, &stamp(&1, [], options))}

    if canonical != calendar, do: rewrite(resource, canonical, options), else: :ok

    canonical
  end

  defp rewrite(resource, calendar, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      store.put(resource.path, ICalendar.write(calendar), @calendar_type, context)
    end

    :ok
  end

  # RFC 6638 section 8.2: the `Schedule-Tag` changes when the
  # *scheduling* content changes, and not otherwise. An attendee
  # editing their own alarm changes the ETag; a client that had only
  # the ETag would resynchronise the whole event every time anyone
  # touched anything, which is the problem this second validator
  # exists to solve. So it is stored, and recomputed only when the
  # organiser, the attendees or the timing actually differ.
  defp restated_body(resource, body, %{store: store, context: context}) do
    with true <- Store.supports?(store, :put),
         {:ok, calendar} <- ICalendar.parse(body),
         canonical = ICalendar.write(calendar),
         true <- canonical != body do
      store.put(resource.path, canonical, @calendar_type, context)
    end

    :ok
  end

  defp stamp_schedule_tag(%{resource: resource, body: body, previous: previous}, options) do
    with %{store: store, context: context} <- options,
         true <- Store.supports?(store, :patch) do
      store.patch(resource, [tagging(resource, body, previous, options)], context)
    end

    :ok
  end

  # An event whose attendees have all been removed is nobody's
  # invitation any more, and a `Schedule-Tag` left behind on it would
  # go on validating a scheduling object that no longer exists. So the
  # property is removed rather than merely left unchanged.
  defp tagging(resource, body, previous, options) do
    if scheduling_body?(body) do
      tag = if unchanged?(body, previous), do: kept_tag(resource, options), else: nil

      {:set, schedule_tag(), tag || fresh_tag(body)}
    else
      {:remove, schedule_tag()}
    end
  end

  defp schedule_tag, do: {Xml.caldav(), "schedule-tag"}

  defp scheduling_body?(body) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      not is_nil(organizer_of(components)) and attendees_of(components) != []
    else
      _not_scheduling -> false
    end
  end

  defp unchanged?(_body, nil), do: false

  defp unchanged?(body, previous), do: scheduling_shape(body) == scheduling_shape(previous)

  # What the attendees agreed to: who is organising, who is invited,
  # and when it happens. Everything else may change without anyone
  # needing to be told — including a `CN`, which the server rewrites
  # on the way in and which names nobody differently, and the
  # parameters the server maintains itself. Those last matter here
  # because this compares a client's body against the stored copy the
  # server normalised, so counting them makes every write look like a
  # change.
  defp scheduling_shape(body) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      for component <- components,
          property <- component.properties,
          property.name in ["ATTENDEE", "ORGANIZER" | @significant],
          into: MapSet.new(),
          do: {property.name, property.value, comparable(property.parameters)}
    else
      _unreadable -> nil
    end
  end

  # An absent `PARTSTAT` *is* `NEEDS-ACTION` — RFC 5545 says so — and
  # the server writes the default out where a client left it implied.
  # Comparing the two spellings as different made every write look
  # like a change of participation.
  defp comparable(parameters) do
    parameters
    |> Map.drop(["CN" | @maintained])
    |> Map.put_new("PARTSTAT", "NEEDS-ACTION")
  end

  defp kept_tag(resource, options), do: stored_schedule_tag(resource, options)

  defp fresh_tag(body), do: ~s("#{:erlang.phash2({body, System.unique_integer()})}")

  defp stored_schedule_tag(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context),
         tag when is_binary(tag) <- Map.get(properties, schedule_tag()) do
      tag
    else
      _absent -> nil
    end
  end

  @doc """
  The `CALDAV:schedule-tag` property of a scheduling object.

  RFC 6638 section 9.3 — the same value as the `Schedule-Tag` header,
  reported as a property so a client can fetch it for a whole
  collection in one PROPFIND rather than a HEAD per resource.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The property when the resource is a scheduling object, and nothing
    otherwise.

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(resource, collection, options) do
    tag =
      for {"schedule-tag", value} <- headers(resource, collection, options),
          do: {{Xml.caldav(), "schedule-tag"}, value}

    tag ++ default_calendar(resource, options) ++ free_busy_set(resource, options)
  end

  # RFC 4791 section 6.2.1, deprecated by RFC 6638 but still asked
  # for: which of the owner's calendars are consulted when somebody
  # asks whether they are free. It is the calendars that are not
  # marked transparent — the same set the free-busy report walks.
  defp free_busy_set(resource, options) do
    if Schedule.inbox?(resource) and is_nil(stated_free_busy_set(resource, options)) do
      hrefs =
        resource
        |> home_calendars(options)
        |> Enum.reject(&FreeBusy.transparent?(&1, options))
        |> Enum.map(&Resource.href/1)

      [{{Xml.caldav(), "calendar-free-busy-set"}, {:hrefs, hrefs}}]
    else
      []
    end
  end

  defp stated_free_busy_set(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context) do
      Map.get(properties, {Xml.caldav(), "calendar-free-busy-set"})
    else
      _none -> nil
    end
  end

  defp home_calendars(inbox, %{store: store, context: context}) do
    with home when is_list(home) <- Enum.drop(inbox.path, -1),
         {:ok, parent} <- store.resolve(home, context),
         {:ok, children} <- store.children(parent, context) do
      Enum.filter(children, &Cal.calendar?/1)
    else
      _nowhere -> []
    end
  end

  # RFC 6638 section 9.2. An invitation has to land somewhere, and
  # `CALDAV:schedule-default-calendar-URL` on the Inbox is where a
  # client asks which calendar that is. A deployment may state it; a
  # deployment that has not is answered with the first calendar in the
  # home, which is where the delivery would go anyway.
  defp default_calendar(resource, options) do
    with true <- Schedule.inbox?(resource),
         nil <- stored_default(resource, options),
         %Resource{} = calendar <- first_calendar(resource, options) do
      [{{Xml.caldav(), "schedule-default-calendar-URL"}, {:hrefs, [Resource.href(calendar)]}}]
    else
      _stated_or_absent -> []
    end
  end

  defp stored_default(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context) do
      Map.get(properties, {Xml.caldav(), "schedule-default-calendar-URL"})
    else
      _none -> nil
    end
  end

  defp first_calendar(inbox, options), do: inbox |> home_calendars(options) |> List.first()

  @doc """
  Deliver the scheduling messages a stored event implies.

  ### Arguments

  * `change` is the `t:Dav.Web.Hook.change/0`. Whose calendar it went
    into decides which way the message goes, and what it replaced
    decides whether the change was significant enough to re-invite
    everyone.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, always.

  """
  @impl Dav.Web.Hook
  @spec written(Dav.Web.Hook.change(), map()) :: :ok
  def written(%{resource: resource, body: body, collection: collection} = change, options) do
    stamp_schedule_tag(change, options)

    with {:ok, parsed} <- ICalendar.parse(body),
         calendar = normalised(resource, parsed, options),
         [_ | _] = components <- schedulable(calendar),
         organizer when not is_nil(organizer) <- organizer_of(components) do
      deliver(
        resource,
        collection,
        calendar,
        components,
        organizer,
        change,
        options
      )
    else
      # Not a scheduling object: an event with no organiser is one
      # person's private appointment, and nobody needs telling — but
      # what was stored is still rewritten in the server's own
      # spelling, so a client reads back what the server understood
      # rather than what it happened to send.
      _nothing_to_schedule -> restated_body(resource, body, options)
    end
  end

  @doc """
  Deliver the scheduling messages a removal implies.

  Deleting a scheduling object is itself a scheduling operation. An
  organiser removing an event cancels it for everyone; an attendee
  removing their copy declines it. Treating DELETE as mere storage
  leaves attendees holding an invitation to a meeting that no longer
  exists, and an organiser believing everyone is still coming.

  ### Arguments

  * `change` is the `t:Dav.Web.Hook.change/0`, whose `:body` is what
    the object held before removal.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, always.

  """
  @impl Dav.Web.Hook
  @spec deleted(Dav.Web.Hook.change(), map()) :: :ok
  def deleted(%{body: body, collection: collection}, options) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar),
         organizer when not is_nil(organizer) <- organizer_of(components),
         addresses when addresses != [] <- owner_addresses(collection, options) do
      withdraw(calendar, components, organizer, addresses, options)
    else
      _nothing_to_schedule -> :ok
    end
  end

  defp withdraw(calendar, components, organizer, addresses, options) do
    zones = zones(calendar)

    if organizer in addresses do
      # The organiser withdrew the event, so it is cancelled for
      # everyone else.
      recipients = Enum.reject(attendees_of(components), &(&1 in addresses))

      send_to(recipients, "CANCEL", components, zones, options, every(components))
    else
      # An attendee removing their copy is declining. The reply carries
      # their own line with `PARTSTAT=DECLINED`, which is how the
      # organiser learns they are not coming rather than simply never
      # hearing back.
      decline(components, organizer, addresses, zones, options)
    end
  end

  # An attendee who already declined has nothing new to say by deleting
  # their copy, and a second identical reply is noise in the
  # organiser's Inbox.
  defp decline(components, organizer, addresses, zones, options) do
    if already_declined?(components, addresses) do
      :ok
    else
      declined = for component <- components, do: declined(only(component, addresses), addresses)

      send_to([organizer], "REPLY", declined, zones, options, every(declined))
    end
  end

  defp declined?(components, address) do
    Enum.any?(components, fn component ->
      Enum.any?(component.properties, fn property ->
        property.name == "ATTENDEE" and property.value == address and
          Map.get(property.parameters, "PARTSTAT") == "DECLINED"
      end)
    end)
  end

  defp already_declined?(components, addresses) do
    Enum.all?(components, fn component ->
      Enum.any?(component.properties, fn property ->
        property.name == "ATTENDEE" and property.value in addresses and
          Map.get(property.parameters, "PARTSTAT") == "DECLINED"
      end)
    end)
  end

  defp declined(component, addresses) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE" and property.value in addresses do
          %{property | parameters: Map.put(property.parameters, "PARTSTAT", "DECLINED")}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  # *All* of them. A recurring event and its overridden instances are
  # several components sharing one UID, and an attendee may appear on
  # an override alone — invited to one Tuesday but not the series.
  # Taking only the first component silently drops those people.
  defp schedulable(calendar) do
    Enum.filter(calendar.components, &(&1.name in ~w(VEVENT VTODO VPOLL)))
  end

  defp organizer_of(components), do: Enum.find_value(components, &value(&1, "ORGANIZER"))

  defp sequenced(components, %{previous: nil}), do: components

  defp sequenced(components, %{previous: previous}) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        # Raised whenever a message goes out, which is the caller's
        # decision: `SEQUENCE` numbers the revisions the attendees
        # were told about, so a second test of what changed here would
        # leave one of them holding an update numbered as the last.
        bumped(components, schedulable(before))

      _unreadable ->
        components
    end
  end

  defp shape(components, names) do
    for component <- components,
        property <- component.properties,
        property.name in names or String.starts_with?(property.name, "X-"),
        into: MapSet.new(),
        do: {property.name, property.value}
  end

  defp bumped(components, held), do: Enum.map(components, &raise_sequence(&1, held))

  # A client that numbers its own revisions is left alone. `SEQUENCE`
  # belongs to the organiser, and their client is entitled to raise it
  # when it edits — so the server only supplies a number when the
  # client has not moved past the one already stored. Adding one to
  # whatever arrived instead put every such event a revision ahead of
  # the copy the attendees were sent.
  defp raise_sequence(component, held) do
    stored = component |> counterpart(held) |> sequence_number()
    sent = sequence_number(component)
    next = if sent > stored, do: sent, else: stored + 1

    properties =
      Enum.reject(component.properties, &(&1.name == "SEQUENCE")) ++
        [%{name: "SEQUENCE", parameters: %{}, value: Integer.to_string(next)}]

    %{component | properties: properties}
  end

  defp counterpart(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence))
  end

  defp sequence_number(nil), do: 0

  defp sequence_number(component), do: component |> value("SEQUENCE") |> to_sequence()

  defp to_sequence(nil), do: 0

  defp to_sequence(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  # RFC 6638 section 7.1: `SCHEDULE-AGENT` says who delivers. Only
  # `SERVER` — the default — means this server. `CLIENT` means the
  # organiser's client will send the invitation itself, and `NONE`
  # means nobody should; delivering anyway sends a duplicate
  # invitation, or one the organiser deliberately suppressed.
  defp attendees_of(components) do
    for component <- components,
        property <- component.properties,
        property.name == "ATTENDEE",
        delivers?(property),
        uniq: true,
        do: property.value
  end

  # This server does not implement `SCHEDULE-AGENT=CLIENT` for an
  # attendee: a client that says it will deliver its own invitation
  # cannot be held to it, and an attendee who is never told is worse
  # than one told twice. The parameter is dropped rather than kept,
  # so nothing later claims a delivery method the server did not use.
  # `NONE` is different — it is the organiser asking for silence, and
  # that is honoured.
  defp delivers?(property) do
    Map.get(property.parameters, "SCHEDULE-AGENT", "SERVER") != "NONE"
  end

  defp promoted(%{name: "ATTENDEE"} = property) do
    if Map.get(property.parameters, "SCHEDULE-AGENT") == "CLIENT",
      do: %{property | parameters: Map.delete(property.parameters, "SCHEDULE-AGENT")},
      else: property
  end

  defp promoted(property), do: property

  # One line per attendee. A client that names somebody twice has said
  # nothing twice over, and keeping both would send them two
  # invitations and count them twice in every reply the organiser
  # reads back.
  defp once_each(component) do
    {properties, _seen} =
      Enum.flat_map_reduce(component.properties, MapSet.new(), fn property, seen ->
        cond do
          property.name != "ATTENDEE" -> {[property], seen}
          property.value in seen -> {[], seen}
          true -> {[property], MapSet.put(seen, property.value)}
        end
      end)

    %{component | properties: properties}
  end

  defp server_delivers?(property) do
    Map.get(property.parameters, "SCHEDULE-AGENT", "SERVER") == "SERVER"
  end

  # A reply says what *this* attendee decided. Anything else they do
  # to their copy — excluding an instance they had already declined,
  # moving an alarm, colouring it — is not news for the organiser, and
  # replying anyway puts a message in their Inbox that says nothing
  # changed.
  defp answered?(%{previous: nil}, _addresses), do: true

  defp answered?(%{body: body, previous: previous}, addresses) do
    now = answers(body, addresses)

    now != still_asked(answers(previous, addresses), now)
  end

  # An attendee who drops an instance they had already declined has
  # told the organiser nothing new. The decline is on record, and the
  # `EXDATE` that follows it is only their own copy catching up with
  # an answer the organiser has had all along.
  defp still_asked(nil, _now), do: nil
  defp still_asked(before, nil), do: before

  defp still_asked(before, now) do
    for {instance, answer} <- before,
        Map.has_key?(now, instance) or answer != "DECLINED",
        into: %{},
        do: {instance, answer}
  end

  defp answers(body, addresses) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      for component <- components,
          property <- component.properties,
          property.name == "ATTENDEE",
          property.value in addresses,
          into: %{},
          do: {value(component, "RECURRENCE-ID"), Map.get(property.parameters, "PARTSTAT")}
    else
      _unreadable -> nil
    end
  end

  defp departed(_components, %{previous: nil}, _addresses), do: []

  defp departed(components, %{previous: previous}, addresses) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        Enum.reject(
          attendees_of(schedulable(before)) -- attendees_of(components),
          &(&1 in addresses)
        )

      _unreadable ->
        []
    end
  end

  # An organiser marked `SCHEDULE-AGENT=CLIENT` is one whose replies
  # this server does not send either.
  defp organizer_delivers?(components) do
    Enum.all?(components, fn component ->
      case Enum.find(component.properties, &(&1.name == "ORGANIZER")) do
        nil -> true
        property -> server_delivers?(property)
      end
    end)
  end

  # Whose copy is this? The owner of the *calendar* decides which way
  # the message goes — the stored object itself carries no owner, and
  # an event in a calendar owned by nobody is not scheduling at all.
  defp deliver(resource, collection, calendar, components, organizer, change, options) do
    case owner_addresses(collection, options) do
      [] -> :ok
      addresses -> route(resource, calendar, components, organizer, addresses, change, options)
    end
  end

  defp route(resource, calendar, components, organizer, addresses, change, options) do
    if organizer in addresses do
      # "The server MUST NOT send a scheduling message to the Attendee
      # that matches the Organizer."
      # Someone who declined does not need the update. Apple's server
      # stops sending to them, and their client has already removed the
      # event — re-delivering puts it back in a calendar they cleared.
      # An organiser marked `SCHEDULE-AGENT=CLIENT` or `NONE` is one
      # whose invitations this server does not send. It still keeps
      # their copy — the event is theirs — but the message is the
      # client's to deliver, or nobody's.
      # Whose answer is whose, settled once: the same components are
      # sent to the attendees and kept for the organiser, so an
      # invitation cannot say one thing in the Inbox and another in
      # the organiser's calendar.
      components =
        components
        |> Enum.map(&remembered(&1, change))
        |> Enum.map(fn component ->
          %{component | properties: Enum.map(component.properties, &promoted/1)}
        end)
        |> Enum.map(&once_each/1)

      recipients =
        if organizer_delivers?(components) do
          components
          |> attendees_of()
          |> Enum.reject(&(&1 in addresses or declined?(components, &1)))
        else
          []
        end

      # Nothing is sent when nothing the attendees can see has changed.
      # An organiser adjusting their own alarm would otherwise put a
      # fresh invitation in every attendee's Inbox, asking them to
      # look at an event that is exactly as they left it.
      told = notified(recipients, change, options)

      # And the version rises exactly when somebody is told. Raised
      # here and not before, because `SEQUENCE` is the organiser's own
      # numbering: an attendee declining one instance adds an
      # `EXDATE`, which looks like a change to the timing and had them
      # advancing it on the organiser's behalf.
      components = if told == [], do: components, else: sequenced(components, change)

      # RFC 5546 section 3.2.5: a withdrawn instance travels as a
      # `CANCEL`, not as a `REQUEST` carrying `STATUS:CANCELLED`. An
      # attendee's client acts on the method, so a cancellation dressed
      # as an invitation leaves the meeting sitting in their calendar.
      withdrawn = Enum.filter(components, &cancelled?/1)

      send_to(
        told,
        "REQUEST",
        components,
        zones(calendar),
        options,
        announced(components, change)
      )

      send_to(told, "CANCEL", withdrawn, zones(calendar), options, every(withdrawn))

      # Anyone dropped from the invitation is told it is off. They are
      # no longer in the attendee list, so nothing else would reach
      # them — and an event they were invited to would sit in their
      # calendar for ever, with no way to learn it had moved on
      # without them.
      dropped = departed(components, change, addresses)

      send_to(dropped, "CANCEL", components, zones(calendar), options, every(components))

      record(resource, restated(calendar, components), recipients, options)
    else
      reply(resource, calendar, components, organizer, addresses, change, options)
    end
  end

  # An iTIP REPLY answers for one attendee. Sending the whole
  # attendee list back would have the organiser's copy record every
  # participant as having just replied, including themselves.
  defp only(component, addresses) do
    properties =
      Enum.reject(component.properties, fn property ->
        property.name == "ATTENDEE" and property.value not in addresses
      end)

    %{component | properties: properties}
  end

  # An invitation nobody has accepted should not block the attendee's
  # time. Apple's clients rely on this, and a calendar that shows every
  # unanswered invitation as busy is unusable after a week.
  # RFC 5545 section 3.8.2.7 defines `TRANSP` for `VEVENT` alone. A
  # to-do does not occupy time — it is due, not scheduled — so there
  # is nothing for it to be transparent about.
  defp untaken(%{name: name} = component) when name != "VEVENT", do: component

  defp untaken(component) do
    if needs_action?(component) do
      %{component | properties: transparent(component.properties)}
    else
      component
    end
  end

  defp needs_action?(component) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION"
    end)
  end

  defp transparent(properties) do
    Enum.reject(properties, &(&1.name == "TRANSP")) ++
      [%{name: "TRANSP", parameters: %{}, value: "TRANSPARENT"}]
  end

  defp reply(resource, calendar, components, organizer, addresses, change, options) do
    cond do
      # RFC 6638 section 3.2.9: "5.3" is "no scheduling support for
      # user". An organiser this server cannot reach, or a copy whose
      # attendee list does not name the person storing it, is one no
      # reply can be sent for — and the owner's client is told so on
      # the `ORGANIZER` rather than left waiting for a delivery that
      # will never happen.
      not answerable?(components, organizer, addresses, options) ->
        record_unschedulable(resource, calendar, organizer, options)

      organizer_delivers?(components) and answered?(change, addresses) ->
        replies = for component <- components, do: only(component, addresses)

        send_to([organizer], "REPLY", replies, zones(calendar), options, every(replies))
        record_reply(resource, calendar, organizer, options)

      true ->
        carry_reply(resource, calendar, organizer, change, options)
    end

    :ok
  end

  defp answerable?(components, organizer, addresses, options) do
    invited? =
      Enum.any?(components, fn component ->
        Enum.any?(
          component.properties,
          &(&1.name == "ATTENDEE" and &1.value in addresses)
        )
      end)

    invited? and not is_nil(home_of(organizer, options))
  end

  defp record_unschedulable(resource, calendar, organizer, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      updated = %{
        calendar
        | components: Enum.map(calendar.components, &unschedulable(&1, organizer))
      }

      store.put(resource.path, ICalendar.write(updated), @calendar_type, context)
    end

    :ok
  end

  defp unschedulable(%{name: "VTIMEZONE"} = zone, _organizer), do: zone

  defp unschedulable(component, organizer) do
    properties =
      Enum.map(component.properties, fn property ->
        # A client that named a `SCHEDULE-AGENT` has already said who
        # delivers, and is not waiting to be told the server will not.
        if property.name == "ORGANIZER" and property.value == organizer and
             not Map.has_key?(property.parameters, "SCHEDULE-AGENT") do
          parameters =
            property.parameters
            |> Map.put("SCHEDULE-AGENT", "NONE")
            |> Map.put("SCHEDULE-STATUS", "5.3")

          %{property | parameters: parameters}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  # `SCHEDULE-STATUS` records what became of the message *you* sent.
  # On the organiser's copy that is one status per attendee, for the
  # invitations. On an attendee's copy it is one status on the
  # ORGANIZER, for the reply — which is how an attendee's client shows
  # that their acceptance actually reached the organiser rather than
  # sitting unsent.
  defp record_reply(resource, calendar, organizer, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      updated = %{
        calendar
        | components: Enum.map(calendar.components, &answered(&1, organizer))
      }

      store.put(resource.path, ICalendar.write(updated), @calendar_type, context)
    end

    :ok
  end

  # The record that an earlier reply reached the organiser survives the
  # attendee's own edits. Their client PUTs the event back without a
  # `SCHEDULE-STATUS` — it never had one to send — and taking the
  # client's word would make every later edit look like an event they
  # had never answered.
  defp carry_reply(resource, calendar, organizer, %{previous: previous}, options)
       when is_binary(previous) do
    with {:ok, before} <- ICalendar.parse(previous),
         true <- stamped?(schedulable(before), organizer),
         false <- stamped?(schedulable(calendar), organizer) do
      record_reply(resource, calendar, organizer, options)
    else
      _nothing_to_carry -> :ok
    end
  end

  defp carry_reply(_resource, _calendar, _organizer, _change, _options), do: :ok

  defp stamped?(components, organizer) do
    Enum.any?(components, fn component ->
      Enum.any?(component.properties, fn property ->
        property.name == "ORGANIZER" and property.value == organizer and
          Map.has_key?(property.parameters, "SCHEDULE-STATUS")
      end)
    end)
  end

  defp answered(%{name: "VTIMEZONE"} = zone, _organizer), do: zone

  defp answered(component, organizer) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ORGANIZER" and property.value == organizer do
          %{property | parameters: Map.put(property.parameters, "SCHEDULE-STATUS", "1.2")}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  # RFC 6638 section 7.3: the organiser's own copy records what became
  # of each invitation, as a `SCHEDULE-STATUS` parameter on the
  # ATTENDEE. That is how an organiser's client shows "invited" beside
  # one name and nothing beside another — without it the organiser has
  # no way to tell a delivered invitation from a lost one.
  defp record(_resource, _calendar, [], _options), do: :ok

  defp record(resource, calendar, recipients, %{store: store, context: context} = options) do
    if Store.supports?(store, :put) do
      updated = %{
        calendar
        | components:
            calendar.components
            |> Enum.map(&stamp(&1, recipients, options))
      }

      store.put(resource.path, ICalendar.write(updated), @calendar_type, context)
    end

    :ok
  end

  # An organiser's client does not know who has accepted — it sends
  # `NEEDS-ACTION` for everyone, because that is what it was given.
  # The server does know, and writing the client's view over its own
  # would un-accept every attendee each time the organiser edited the
  # event. RFC 6638 section 3.2.1 says as much: an organiser may not
  # set another participant's PARTSTAT.
  #
  # A *significant* change is the exception: moving the event asks
  # everyone again, and the organiser's `NEEDS-ACTION` is then the
  # right answer rather than a client's ignorance.
  defp remembered(component, %{previous: nil}), do: restore_participation(component, [])

  defp remembered(component, %{previous: previous}) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)

        # An answer is the attendee's own and the stored one stands —
        # an organiser's client does not know what anyone said and
        # must not overwrite it in passing. A *significant* change is
        # different: when the timing moves, everyone is being asked
        # again, and their last answer was to a different meeting.
        if asked_again?(component, held),
          do: restore_participation(component, []),
          else: restore_participation(component, held)

      _unreadable ->
        component
    end
  end

  defp asked_again?(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    case Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence)) do
      nil -> false
      before -> shape([component], @rescheduled) != shape([before], @rescheduled)
    end
  end

  defp restore_participation(component, existing) do
    known =
      for old <- existing,
          value(old, "RECURRENCE-ID") == value(component, "RECURRENCE-ID"),
          property <- old.properties,
          property.name == "ATTENDEE",
          status = Map.get(property.parameters, "PARTSTAT"),
          not is_nil(status),
          into: %{},
          do: {property.value, status}

    organizer = value(component, "ORGANIZER")

    %{
      component
      | properties:
          component.properties
          |> Enum.map(&participating(&1, known, organizer))
    }
  end

  # `NEEDS-ACTION` is the one answer an organiser may give on someone
  # else's behalf: it is not a claim about what they decided, it is
  # the question being asked again. Every other value is theirs alone,
  # and the stored one stands — an organiser's client sending
  # `DECLINED` for an attendee who accepted is reporting its own
  # ignorance, not their change of mind.
  # The organiser answers for themselves, and one who invites
  # themselves has plainly accepted. Every other answer is its
  # owner's: the stored one stands, and where there is none — a first
  # invitation, or an attendee just added — nobody has been asked yet.
  # An organiser's client sending `ACCEPTED` for everyone it invites
  # is reporting its own ignorance, and storing it shows a meeting the
  # whole room agreed to before anyone heard of it.
  defp participating(%{name: "ATTENDEE", value: value} = property, known, organizer) do
    cond do
      value == organizer ->
        property

      # `NEEDS-ACTION` is the one answer an organiser may give for
      # somebody else: it is not a claim about what they decided, it
      # is the question being put again. Every other value is theirs
      # alone and the stored one stands.
      Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION" ->
        %{property | parameters: awaiting(property.parameters)}

      true ->
        %{property | parameters: answered_or_asked(property.parameters, known, value)}
    end
  end

  defp participating(property, _known, _organizer), do: property

  # Being put back to `NEEDS-ACTION` is being asked, and asking
  # carries `RSVP=TRUE` — the attendee's client uses it to know a
  # reply is wanted rather than that the event simply appeared.
  defp answered_or_asked(parameters, known, value) do
    # A room does not deliberate. Nobody sits at its keyboard to
    # accept, so the server answers for it the moment it is invited —
    # and records that answer as one it processed itself.
    if unattended?(parameters) do
      parameters |> Map.put("PARTSTAT", "ACCEPTED") |> Map.put("SCHEDULE-STATUS", "2.0")
    else
      case Map.fetch(known, value) do
        {:ok, answer} -> awaiting(Map.put(parameters, "PARTSTAT", answer))
        :error -> awaiting(Map.put(parameters, "PARTSTAT", "NEEDS-ACTION"))
      end
    end
  end

  # Still to answer is still being asked. `RSVP=TRUE` is not a
  # separate fact from `PARTSTAT=NEEDS-ACTION` — it is what tells the
  # attendee's client that a reply is wanted — so the two travel
  # together, and once somebody has answered the asking stops.
  defp awaiting(parameters) do
    if Map.get(parameters, "PARTSTAT") == "NEEDS-ACTION",
      do: Map.put(parameters, "RSVP", "TRUE"),
      else: Map.delete(parameters, "RSVP")
  end

  defp unattended?(parameters), do: Map.get(parameters, "CUTYPE") in ~w(RESOURCE ROOM)

  defp stamp(component, recipients, options) do
    properties =
      component.properties
      |> Enum.map(&delivered(&1, recipients))
      |> Enum.map(&canonical(&1, options))

    %{component | properties: properties}
  end

  # One person may be addressed several ways. Storing whichever
  # spelling arrived means an attendee's reply does not match the
  # invitation they were sent, so addresses are normalised to the form
  # the store considers canonical.
  defp canonical(%{name: name, value: value} = property, options)
       when name in ~w(ATTENDEE ORGANIZER) do
    address = canonical_address(value, options)

    %{property | value: address, parameters: named(property.parameters, address, options)}
  end

  defp canonical(property, _options), do: property

  # The `CN` is the server's to state, not the client's. A client that
  # writes "User 01 Bogus" beside a real address has invented a name
  # for someone who has one, and every other participant would see the
  # invention rather than the person.
  defp named(parameters, address, options) do
    case common_name(address, options) do
      nil -> parameters
      name -> Map.put(parameters, "CN", name)
    end
  end

  defp common_name(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{display_name: name}} when is_binary(name) <-
           store.principal(address, context) do
      name
    else
      _unknown -> nil
    end
  end

  defp canonical_address(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :canonical_address, 2),
         {:ok, canonical} <- store.canonical_address(address, context) do
      canonical
    else
      _not_hosted_here -> address
    end
  end

  # "1.2" is iTIP's "scheduling message has been delivered".
  defp delivered(%{name: "ATTENDEE", value: value} = property, recipients) do
    if value in recipients do
      %{property | parameters: Map.put(property.parameters, "SCHEDULE-STATUS", "1.2")}
    else
      property
    end
  end

  defp delivered(property, _recipients), do: property

  # The VTIMEZONEs the event refers to. A delivered copy without them
  # names a zone the recipient's client cannot resolve, and RFC 4791
  # section 4.1 requires them alongside the component.
  defp zones(calendar), do: Enum.filter(calendar.components, &(&1.name == "VTIMEZONE"))

  # `SCHEDULE-STATUS` records what became of a message *this* server
  # sent, on the copy of whoever sent it. It has no meaning to the
  # recipient — telling an attendee that their own invitation was
  # delivered to them is nonsense — so it is stripped in transit.
  defp unstamped(component) do
    properties =
      Enum.map(component.properties, fn property ->
        %{property | parameters: Map.delete(property.parameters, "SCHEDULE-STATUS")}
      end)

    %{component | properties: properties}
  end

  defp cancelled?(component), do: value(component, "STATUS") == "CANCELLED"

  defp send_to([], _method, _components, _zones, _options, _announced), do: :ok
  defp send_to(_recipients, _method, [], _zones, _options, _announced), do: :ok

  defp send_to(recipients, method, components, zones, options, announced) do
    # The delivered copy carries canonical addresses too. Sending one
    # spelling and storing another is how an attendee's reply stops
    # matching the invitation it answers.
    normalised =
      for component <- components,
          do:
            component
            |> stamp([], options)
            |> unstamped()
            |> without_alarms()
            |> unagented()
            |> unextended(extensions(options))

    told =
      for component <- normalised, value(component, "RECURRENCE-ID") in announced, do: component

    for recipient <- recipients, home = home_of(recipient, options), not is_nil(home) do
      deliver_to(home, recipient, method, normalised, told, zones, options)
    end

    :ok
  end

  # Substituted in place, not rebuilt. Collecting the timezones and
  # appending the schedulable components drops anything that is
  # neither, and reorders what survives.
  defp restated(calendar, components) do
    revised =
      Map.new(components, &{{&1.name, value(&1, "RECURRENCE-ID")}, &1})

    replaced =
      Enum.map(calendar.components, fn component ->
        Map.get(revised, {component.name, value(component, "RECURRENCE-ID")}, component)
      end)

    %{calendar | components: replaced}
  end

  defp notified(recipients, %{previous: nil}, _options), do: recipients

  defp notified(recipients, %{body: body, previous: previous}, options) do
    if shared(body, options) == shared(previous, options), do: [], else: recipients
  end

  # The event as the attendees see it. Alarms are removed because they
  # are personal; the timestamps because every save moves them and no
  # attendee is waiting to hear it; and the parameters the server
  # maintains because they record what became of past messages rather
  # than anything this one carries.
  defp shared(body, options) do
    allowed = extensions(options)

    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      for component <-
            components |> Enum.map(&without_alarms/1) |> Enum.map(&unextended(&1, allowed)),
          property <- component.properties,
          property.name not in @bookkeeping,
          into: MapSet.new(),
          do: {property.name, addressed_as(property, options), comparable(property.parameters)}
    else
      _unreadable -> nil
    end
  end

  # A person, not a spelling. The client writes `mailto:` where the
  # server holds `urn:x-uid:`, and comparing the two as text makes
  # every save look like a change of attendee — which puts a fresh
  # invitation in everybody's Inbox each time the organiser edits a
  # word of the summary.
  defp addressed_as(%{name: name, value: value}, options) when name in ~w(ATTENDEE ORGANIZER),
    do: canonical_address(value, options)

  defp addressed_as(%{value: value}, _options), do: value

  # Which instances the message itself carries. An update that touches
  # one Tuesday is announced as that Tuesday: sending the whole
  # recurrence set asks the recipient to re-read a series they already
  # have, and their client cannot tell which part is news. The copy
  # kept in their calendar is still the whole set — only the message
  # is narrowed.
  defp announced(components, %{previous: nil}), do: every(components)

  defp announced(components, %{previous: previous}) do
    case ICalendar.parse(previous) do
      {:ok, before} -> altered(components, schedulable(before)) || every(components)
      _unreadable -> every(components)
    end
  end

  # `nil` rather than `[]` when nothing changed, so the caller falls
  # back to announcing everything: a message with no components at all
  # is not a smaller message, it is a broken one.
  defp altered(components, held) do
    case for component <- components, altered?(component, held), do: recurrence(component) do
      [] -> nil
      some -> some
    end
  end

  defp every(components), do: for(component <- components, do: recurrence(component))

  defp recurrence(component), do: value(component, "RECURRENCE-ID")

  defp altered?(component, held) do
    case Enum.find(held, &(recurrence(&1) == recurrence(component))) do
      nil -> true
      previous -> instance(component) != instance(previous)
    end
  end

  defp instance(component) do
    for property <- component.properties,
        property.name not in @bookkeeping,
        into: MapSet.new(),
        do: {property.name, property.value, Map.drop(property.parameters, @maintained)}
  end

  defp extensions(options), do: Map.get(options, :extensions) || @public

  # An `X-` property is private to whoever wrote it unless it is one
  # of the few that describe the meeting rather than the copy. The
  # organiser's client may hang anything it likes off its own event —
  # a colour, a local identifier, a sync marker — and none of it means
  # the same on an attendee's, where a different client will read it.
  # A structured location does: it is where everyone is going.
  defp unextended(component, allowed) do
    kept =
      component.properties
      |> Enum.reject(&private?(&1.name, allowed))
      |> Enum.map(&public_parameters(&1, allowed))

    %{component | properties: kept}
  end

  # Parameters follow the same rule as properties. A client may hang
  # its own on an `ORGANIZER` or `ATTENDEE`, and they are no more
  # meaningful to a recipient than a private property would be.
  defp public_parameters(property, allowed) do
    kept =
      for {name, value} <- property.parameters,
          not private?(name, allowed),
          into: %{},
          do: {name, value}

    %{property | parameters: kept}
  end

  defp private?(name, allowed) do
    String.starts_with?(name, "X-") and name not in allowed
  end

  # `SCHEDULE-AGENT` says who is expected to deliver *this* message.
  # It is the organiser's own bookkeeping, kept on their copy and
  # meaningless on a recipient's: by the time it arrives, the question
  # of who would deliver it has been answered.
  defp unagented(component) do
    properties =
      Enum.map(component.properties, fn property ->
        %{property | parameters: Map.delete(property.parameters, "SCHEDULE-AGENT")}
      end)

    %{component | properties: properties}
  end

  # RFC 5546 section 3.6: an alarm is the property of whoever set it.
  # The organiser's reminder to leave early says nothing to an
  # attendee in another city, and delivering it puts an alert in their
  # calendar that they never asked for and cannot trace.
  defp without_alarms(component) do
    %{component | components: Enum.reject(component.components, &(&1.name == "VALARM"))}
  end

  # A scheduling message reaches two places, and both matter. The Inbox
  # copy is the *message* — RFC 6638 section 4 — and it is what a
  # client polls to learn something happened. The calendar copy is the
  # event itself, so that an invitation appears in the attendee's
  # calendar rather than only in a queue they may never read.
  #
  # A REPLY has no calendar copy: the organiser already has the event,
  # and what has changed is one attendee's participation.
  defp deliver_to(home, recipient, method, components, told, zones, options) do
    uid = Enum.find_value(components, &value(&1, "UID"))

    case collection(home, &Schedule.inbox?/1, options) do
      nil ->
        :ok

      inbox ->
        deposit(
          inbox,
          message(method, told, zones),
          uid,
          options,
          addressing(method, components, recipient)
        )
    end

    case {method, collection(home, &Cal.calendar?/1, options)} do
      {"REQUEST", %Resource{} = calendar} ->
        store(
          calendar,
          own_copy(preserving(calendar, recipient, components, uid, options), zones),
          uid,
          options
        )

      {"REPLY", %Resource{} = calendar} ->
        apply_reply(calendar, components, uid, options)

      # A cancelled event is *marked* cancelled, not removed. The
      # attendee had it in their calendar and may have arranged their
      # day around it; making it vanish leaves them wondering where it
      # went, while `STATUS:CANCELLED` says what happened and lets
      # them delete it themselves.
      {"CANCEL", %Resource{} = calendar} ->
        cancel(calendar, components, uid, options)

      _no_calendar ->
        :ok
    end

    :ok
  end

  # A REPLY is not just a message to read: the organiser's own copy of
  # the event has to show that this attendee accepted. Delivering the
  # reply to the Inbox and leaving the event unchanged means the
  # organiser's calendar shows everyone as NEEDS-ACTION for ever —
  # RFC 6638 section 4.2 makes applying it the server's job.
  defp apply_reply(calendar, replies, uid, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      answered = Enum.map(stored.components, &accept(&1, matching(&1, replies)))

      updated = %{stored | components: answered ++ separated(stored, replies)}

      write(object, ICalendar.write(updated), options)
      refreshed(updated, uid, answering(replies), options)
    else
      _no_such_event -> :ok
    end
  end

  # Everyone else's copy learns the answer too. An attendee's client
  # shows the guest list, and without this each of them sees every
  # other participant as never having replied — the organiser knows
  # who accepted and nobody else does. It goes straight into their
  # calendar rather than their Inbox: nothing is being asked of them,
  # and a message would have their client offer a meeting they are
  # already holding.
  defp refreshed(updated, uid, answering, options) do
    components = schedulable(updated)
    organizer = Enum.find_value(components, &value(&1, "ORGANIZER"))

    for address <- attendees_of(components),
        address != organizer,
        address not in answering,
        home = home_of(address, options),
        not is_nil(home),
        calendar = collection(home, &Cal.calendar?/1, options),
        not is_nil(calendar) do
      restated_for(calendar, uid, address, components, options)
    end

    :ok
  end

  defp answering(replies) do
    for component <- replies,
        property <- component.properties,
        property.name == "ATTENDEE",
        uniq: true,
        do: property.value
  end

  defp restated_for(calendar, uid, address, components, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      revised = Enum.map(stored.components, &restated_component(&1, components, address))

      write(object, ICalendar.write(%{stored | components: revised}), options)
    else
      _no_copy_of_their_own -> :ok
    end
  end

  defp restated_component(component, components, address) do
    case Enum.find(components, &(value(&1, "RECURRENCE-ID") == value(component, "RECURRENCE-ID"))) do
      nil -> component
      known -> retold(component, known, address)
    end
  end

  # Their own line is theirs; every other participant's is the
  # organiser's to state.
  defp retold(component, known, address) do
    answers =
      for property <- known.properties,
          property.name == "ATTENDEE",
          property.value != address,
          into: %{},
          do: {property.value, Map.get(property.parameters, "PARTSTAT")}

    properties =
      Enum.map(component.properties, fn property ->
        with "ATTENDEE" <- property.name,
             {:ok, answer} when is_binary(answer) <- Map.fetch(answers, property.value) do
          # `RSVP=TRUE` is the question, not the answer. Somebody who
          # has replied is no longer being asked.
          parameters = Map.put(property.parameters, "PARTSTAT", answer)

          %{
            property
            | parameters:
                if(answer == "NEEDS-ACTION",
                  do: parameters,
                  else: Map.delete(parameters, "RSVP")
                )
          }
        else
          _theirs_or_unknown -> property
        end
      end)

    %{component | properties: properties}
  end

  # RFC 5546 section 3.2.3: an attendee may answer for one instance of
  # a series the organiser holds only as a rule. The reply names it by
  # `RECURRENCE-ID`, and the organiser's copy has to gain an override
  # to record the answer — with nowhere to put it, their decision
  # about that one Tuesday is simply lost.
  defp separated(stored, replies) do
    held = schedulable(stored)
    known = for component <- held, do: value(component, "RECURRENCE-ID")

    case Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID"))) do
      nil ->
        []

      master ->
        for reply <- replies,
            recurrence = recurrence_of(reply),
            not is_nil(recurrence),
            recurrence.value not in known,
            do: accept(overridden(master, recurrence), [reply])
    end
  end

  defp recurrence_of(component) do
    Enum.find(component.properties, &(&1.name == "RECURRENCE-ID"))
  end

  # An override is the master with the rule taken off and the instance
  # it replaces named. What recurs is the series; this is one date —
  # and it is *that* date, not the one the series starts on, so
  # `DTSTART` moves to the instance the `RECURRENCE-ID` picks out.
  defp overridden(master, recurrence) do
    kept =
      master.properties
      |> Enum.reject(&(&1.name in ~w(RRULE RDATE EXDATE RECURRENCE-ID DTSTART)))
      |> Kernel.++([%{recurrence | name: "DTSTART"}, recurrence])

    %{master | properties: kept}
  end

  # The reply carries the attendee's own PARTSTAT; everything else in
  # the organiser's copy stays as the organiser wrote it.
  # A reply answers for one occurrence. An attendee who accepted the
  # series and declined a single Tuesday sends two components, and
  # applying either to every occurrence loses the distinction —
  # the whole series ends up declined, or the exception accepted.
  defp matching(component, replies) do
    instance = value(component, "RECURRENCE-ID")

    Enum.filter(replies, &(value(&1, "RECURRENCE-ID") == instance))
  end

  defp accept(component, replies) do
    answers =
      for reply <- replies,
          property <- reply.properties,
          property.name == "ATTENDEE",
          into: %{},
          do: {property.value, property.parameters}

    %{component | properties: Enum.map(component.properties, &participation(&1, answers))}
  end

  defp participation(%{name: "ATTENDEE", value: value} = property, replies) do
    case Map.fetch(replies, value) do
      {:ok, parameters} ->
        # "2.0" is iTIP's "request succeeded", which is what the
        # organiser's client shows as a confirmed attendee.
        %{
          property
          | parameters:
              property.parameters
              |> Map.merge(Map.take(parameters, ["PARTSTAT"]))
              |> Map.delete("RSVP")
              |> Map.put("SCHEDULE-STATUS", "2.0")
        }

      :error ->
        property
    end
  end

  defp participation(property, _replies), do: property

  # By UID, not by file name. A client names its own resources, and
  # `1.ics` holding an event whose UID is a long opaque string is the
  # normal case rather than the exception.
  defp cancel(calendar, components, uid, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      withdrawn = for component <- components, do: value(component, "RECURRENCE-ID")

      updated = %{
        stored
        | components: Enum.map(stored.components, &cancelled_if(&1, withdrawn, components))
      }

      write(object, ICalendar.write(updated), options)
    else
      _no_such_event -> :ok
    end
  end

  # A `CANCEL` names the instances it withdraws. One carrying the
  # master — a component with no `RECURRENCE-ID` — withdraws the whole
  # series; one naming a single override leaves the rest standing.
  # Cancelling everything regardless cleared an attendee's calendar of
  # meetings that are still going ahead.
  defp cancelled_if(%{name: "VTIMEZONE"} = zone, _withdrawn, _sent), do: zone

  defp cancelled_if(component, withdrawn, sent) do
    if nil in withdrawn or value(component, "RECURRENCE-ID") in withdrawn,
      do: component |> cancelled(nil) |> numbered(sent),
      else: component
  end

  # The withdrawal carries its own version, and the copy it cancels
  # takes it. A recipient left holding the version they were invited
  # at cannot tell a cancellation from the invitation it withdraws.
  defp numbered(component, sent) do
    with %{} = counterpart <-
           Enum.find(sent, &(value(&1, "RECURRENCE-ID") == value(component, "RECURRENCE-ID"))),
         sequence when is_binary(sequence) <- value(counterpart, "SEQUENCE") do
      properties =
        Enum.reject(component.properties, &(&1.name == "SEQUENCE")) ++
          [%{name: "SEQUENCE", parameters: %{}, value: sequence}]

      %{component | properties: properties}
    else
      _unnumbered -> component
    end
  end

  defp cancelled(%{name: "VTIMEZONE"} = zone, _component), do: zone

  defp cancelled(component, _cancellation) do
    properties =
      Enum.reject(component.properties, &(&1.name == "STATUS")) ++
        [%{name: "STATUS", parameters: %{}, value: "CANCELLED"}]

    %{component | properties: properties}
  end

  defp object_with(calendar, uid, %{store: store, context: context} = options) do
    case store.children(calendar, context) do
      {:ok, children} -> Enum.find(children, &(uid_of(&1, options) == uid))
      _nothing -> nil
    end
  end

  defp uid_of(object, options) do
    with {:ok, body} <- read(object, options),
         {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      Enum.find_value(components, &value(&1, "UID"))
    else
      _unreadable -> nil
    end
  end

  defp read(object, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(object, context) do
      {:ok, IO.iodata_to_binary(data)}
    else
      _unreadable -> :error
    end
  end

  defp write(object, body, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      store.put(object.path, body, @calendar_type, context)
    end

    :ok
  end

  # The attendee's own copy carries no METHOD: it is an event in their
  # calendar, not a message about one.
  # A re-sent invitation must not silently un-accept the attendee. An
  # organiser fixing a typo in the summary re-delivers the whole event,
  # and overwriting the attendee's copy wholesale would reset their
  # PARTSTAT to NEEDS-ACTION and lose the record that their reply
  # reached the organiser. Their own participation is carried over.
  #
  # A *significant* change is different: when the timing moves, the
  # attendee is asked again.
  defp preserving(calendar, recipient, components, uid, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, existing} <- ICalendar.parse(body) do
      held = schedulable(existing)

      kept =
        if resequenced?(components, held),
          do: Enum.map(components, &carry_organizer(&1, held)),
          else: Enum.map(components, &carry_over(&1, recipient, held))

      Enum.map(kept, &carry_alarms(&1, held))
    else
      _no_previous_copy -> components
    end
  end

  # The recipient's own alarms survive the update. A scheduling
  # message carries none — they are personal, and the sender's are
  # stripped on the way out — so writing the message over the stored
  # copy silently deleted whatever reminder the attendee had set for
  # themselves. The event may move; their wish to be told about it
  # beforehand does not.
  defp carry_alarms(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    case Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence)) do
      nil -> component
      previous -> %{component | components: alarms_of(previous) ++ component.components}
    end
  end

  defp alarms_of(component), do: Enum.filter(component.components, &(&1.name == "VALARM"))

  # Being asked again resets the recipient's own answer, but not the
  # record that the answer they gave last time reached the organiser.
  # That `SCHEDULE-STATUS` on the `ORGANIZER` is this copy's only
  # evidence that the attendee is in touch at all, and dropping it
  # made every re-invitation look like a first one.
  defp carry_organizer(component, held) do
    kept =
      for old <- held,
          property <- old.properties,
          property.name == "ORGANIZER",
          into: %{},
          do: {{property.name, property.value}, property.parameters}

    %{component | properties: Enum.map(component.properties, &restore(&1, kept))}
  end

  # Whether the attendees must answer again. `SEQUENCE` rising is not
  # the test: it also rises for a changed subject, which the attendees
  # need to see but need not re-accept. What re-asks them is a change
  # to when or where the event happens.
  defp resequenced?(now, before), do: shape(now, @rescheduled) != shape(before, @rescheduled)

  # The recipient's *own* participation, and the ORGANIZER status
  # recording that their reply was delivered — and nothing else. What
  # the other attendees have since answered is the organiser's to say,
  # and keeping this copy's stale view of them would tell each
  # attendee that everyone else is still undecided.
  defp carry_over(component, recipient, existing) do
    kept =
      for old <- existing,
          property <- old.properties,
          property.name == "ORGANIZER" or property.value == recipient,
          property.name in ~w(ATTENDEE ORGANIZER),
          into: %{},
          do: {{property.name, property.value}, property.parameters}

    %{component | properties: Enum.map(component.properties, &restore(&1, kept))}
  end

  defp restore(%{name: name, value: value} = property, kept)
       when name in ~w(ATTENDEE ORGANIZER) do
    case Map.fetch(kept, {name, value}) do
      {:ok, parameters} ->
        %{property | parameters: Map.merge(property.parameters, taken(parameters))}

      :error ->
        property
    end
  end

  defp restore(property, _kept), do: property

  defp taken(parameters), do: Map.take(parameters, ["PARTSTAT", "SCHEDULE-STATUS"])

  defp own_copy(components, zones) do
    ICalendar.write(%{
      name: "VCALENDAR",
      properties: [
        %{name: "VERSION", parameters: %{}, value: "2.0"},
        %{name: "PRODID", parameters: %{}, value: "-//Dav//CalDAV//EN"}
      ],
      components: zones ++ Enum.map(components, &untaken/1)
    })
  end

  # The calendar user addresses of whoever owns this resource, found by
  # asking the store which principal each address belongs to. A store
  # without that lookup cannot schedule, and says so by answering
  # nothing rather than by guessing.
  @doc """
  The calendar user addresses of whoever owns a collection.

  ### Arguments

  * `collection` is the collection being written into, or `nil`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The list of addresses, or `[]` when the store cannot resolve them.
    An empty list means "unknown", not "nobody": callers treat it as a
    reason to skip a decision rather than to refuse one.

  ### Examples

      iex> Dav.Cal.Scheduling.addresses_of(nil, %{})
      []

  """
  @spec addresses_of(Resource.t() | nil, map()) :: [String.t()]
  def addresses_of(collection, options), do: owner_addresses(collection, options)

  @doc """
  Whether a calendar user address belongs to this server.

  ### Arguments

  * `address` is a calendar user address, as an `ORGANIZER` or
    `ATTENDEE` carries it.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `true` when the store can resolve the address to a calendar home
    it hosts, and `false` otherwise — including when the store offers
    no lookup at all.

  ### Examples

      iex> Dav.Cal.Scheduling.hosted?("mailto:nobody@example.com", %{store: Dav.Web.Store, context: nil})
      false

  """
  @spec hosted?(String.t() | nil, map()) :: boolean()
  def hosted?(nil, _options), do: false
  def hosted?(address, options), do: not is_nil(home_of(address, options))

  defp owner_addresses(nil, _options), do: []
  defp owner_addresses(%Resource{owner: nil}, _options), do: []

  # Without an explicit lookup the principal URL is all there is, and
  # comparing it against an `ORGANIZER` of `mailto:...` would never
  # match — so scheduling is skipped rather than guessed at.
  defp owner_addresses(%Resource{owner: owner}, %{store: store, context: context}) do
    with true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(owner, context) do
      addresses
    else
      _no_lookup -> []
    end
  end

  defp home_of(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context) do
      home
    else
      _unknown_recipient -> nil
    end
  end

  defp collection(home, matches?, %{store: store, context: context}) do
    case store.children(home, context) do
      {:ok, children} -> Enum.find(children, matches?)
      _nothing -> nil
    end
  end

  # A delivered copy is written straight to the store, which is right —
  # it is the server's own act, not a client's request, and running the
  # hooks again would have the delivery re-schedule itself. But that
  # also means nothing stamps its `Schedule-Tag`, so this does.
  # An Inbox holds messages, not the event. Two messages about one
  # event — an update and a cancellation of one instance — are two
  # things to read, and writing both under the event's `UID` leaves
  # the recipient with only whichever arrived last.
  defp deposit(collection, body, uid, options, addressing) do
    store(collection, body, unused(collection, uid || "message", options), options, addressing)
  end

  defp unused(collection, name, %{store: store, context: context}) do
    Stream.concat([name], Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{name}-#{&1}"))
    |> Enum.find(fn candidate ->
      match?(
        {:error, :not_found},
        store.resolve(collection.path ++ ["#{candidate}.ics"], context)
      )
    end)
  end

  defp store(collection, body, uid, options, addressing \\ [])

  defp store(collection, body, uid, %{store: store, context: context} = options, addressing) do
    if Store.supports?(store, :put) do
      path = collection.path ++ [(uid || "message") <> ".ics"]

      case store.put(path, body, @calendar_type, context) do
        {:ok, _outcome, resource} ->
          tag(resource, body, options)
          addressed(resource, addressing, options)

        _refused ->
          :ok
      end
    end
  end

  # A message in an Inbox records who sent it and who it was sent to.
  # The recipient's client reads them to tell an invitation addressed
  # to them apart from one delivered to a calendar they read on
  # somebody else's behalf, which the message body does not say.
  defp addressed(_resource, [], _options), do: :ok

  defp addressed(resource, addressing, %{store: store, context: context}) do
    if Store.supports?(store, :patch), do: store.patch(resource, addressing, context)

    :ok
  end

  defp addressing(method, components, recipient) do
    case originator(method, components) do
      nil ->
        []

      sender ->
        [
          {:set, {Xml.caldav(), "originator"}, {:hrefs, [sender]}},
          {:set, {Xml.caldav(), "recipient"}, {:hrefs, [recipient]}}
        ]
    end
  end

  # Whoever the message is from: an invitation or a cancellation comes
  # from the organiser, and a reply from the one attendee it answers
  # for.
  defp originator("REPLY", components) do
    Enum.find_value(components, fn component ->
      Enum.find_value(component.properties, &if(&1.name == "ATTENDEE", do: &1.value))
    end)
  end

  defp originator(_method, components), do: Enum.find_value(components, &value(&1, "ORGANIZER"))

  # A delivered copy gets a *new* tag every time. This is the arrival
  # of a scheduling message, which is precisely what the tag tracks —
  # keeping the old one told the recipient's client that nothing had
  # reached it since the last time it looked, while a fresh
  # invitation sat in the calendar.
  defp tag(resource, body, %{store: store, context: context}) do
    if scheduling_body?(body) and Store.supports?(store, :patch) do
      store.patch(resource, [{:set, schedule_tag(), fresh_tag(body)}], context)
    end

    :ok
  end

  defp message(method, components, zones) do
    ICalendar.write(%{
      name: "VCALENDAR",
      properties: [
        %{name: "VERSION", parameters: %{}, value: "2.0"},
        %{name: "PRODID", parameters: %{}, value: "-//Dav//CalDAV//EN"},
        %{name: "METHOD", parameters: %{}, value: method}
      ],
      components: zones ++ components
    })
  end

  defp value(component, name) do
    case Enum.find(component.properties, &(&1.name == name)) do
      nil -> nil
      found -> found.value
    end
  end
end
