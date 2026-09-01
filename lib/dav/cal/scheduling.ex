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
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  # The type the suite expects a stored calendar object to report,
  # parameter included: a client that asked for `charset=utf-8` on the
  # way in is entitled to see it on the way out.
  @calendar_type "text/calendar;charset=utf-8"

  # When the meeting itself moves — the changes that ask an attendee
  # to answer again, per occurrence. The reference's
  # `attendeeNeedsAction` list exactly: an event being called off, or
  # moving down the corridor, is news they need without being
  # re-asked, so `LOCATION` and `STATUS` are not here — and neither is
  # `RRULE`, which is judged at the series level, where a truncation
  # is excused.
  @rescheduled ~w(DTSTART DTEND DURATION DUE RECURRENCE-ID)

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

  # Extensions that describe *this copy* rather than the event. They
  # stay where they are written — a client sets one and expects it
  # back — but they are nobody else's news: `X-APPLE-NEEDS-REPLY`
  # says whether the holder still owes an answer, which is a
  # different fact for every participant.
  @per_copy ~w(X-APPLE-NEEDS-REPLY X-APPLE-TRAVEL-DURATION X-APPLE-TRAVEL-START X-APPLE-TRAVEL-RETURN-DURATION X-APPLE-TRAVEL-RETURN)
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
    canonical = %{
      calendar
      | components:
          calendar.components
          |> repaired_recurrences()
          |> Enum.map(&stamp(&1, [], options))
    }

    if canonical != calendar, do: rewrite(resource, canonical, options), else: :ok

    canonical
  end

  # A `RECURRENCE-ID` at midnight on a day whose instance is at
  # another time is a known client slip — the identifier was derived
  # from the date instead of the occurrence. It is snapped to the
  # instance the rule produces that day rather than refused: the
  # client meant that day's meeting, and said so.
  defp repaired_recurrences(components) do
    master =
      Enum.find(
        components,
        &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID")) and
            Enum.any?(&1.properties, fn property -> property.name == "RRULE" end))
      )

    if master, do: Enum.map(components, &snapped_midnight(&1, master)), else: components
  end

  defp snapped_midnight(%{name: "VTIMEZONE"} = zone, _master), do: zone

  defp snapped_midnight(component, master) do
    properties =
      Enum.map(component.properties, fn property ->
        with "RECURRENCE-ID" <- property.name,
             [date, time] when time in ["000000", "000000Z"] <-
               String.split(property.value, "T", parts: 2),
             instance when is_binary(instance) <- day_instance(master, property.parameters, date) do
          %{property | value: instance}
        else
          _not_a_midnight_slip -> property
        end
      end)

    %{component | properties: properties}
  end

  defp day_instance(master, parameters, date) do
    with start when is_binary(start) <- value(master, "DTSTART"),
         [_start_date, start_time] <- String.split(start, "T", parts: 2),
         candidate = date <> "T" <> start_time,
         true <- TimeRange.occurs?(master, parameters, candidate) do
      candidate
    else
      _no_instance_that_day -> nil
    end
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
  defp restated_body(resource, body, calendar, %{store: store, context: context}) do
    with true <- Store.supports?(store, :put),
         canonical = ICalendar.write(calendar),
         true <- canonical != body do
      store.put(resource.path, canonical, @calendar_type, context)
    end

    :ok
  end

  defp stamp_schedule_tag(%{resource: resource, body: body, previous: previous}, options) do
    with %{store: store, context: context} <- options,
         true <- Store.supports?(store, :patch) do
      operations = [
        tagging(resource, body, previous, options) | reset_etags(resource, body, options)
      ]

      store.patch(resource, operations, context)
    end

    :ok
  end

  # An event whose attendees have all been removed is nobody's
  # invitation any more, and a `Schedule-Tag` left behind on it would
  # go on validating a scheduling object that no longer exists. So the
  # property is removed rather than merely left unchanged.
  # A fresh tag on every client write. `Schedule-Tag` exists so a
  # change the *server* makes — applying an attendee's reply to the
  # organiser's copy — moves the `ETag` without moving it; those
  # writes go straight to the store and never pass this hook, so
  # everything that does arrive here is a client's own edit. An
  # earlier version kept the tag when the scheduling *shape* was
  # unchanged, which quietly kept it across an alarm being removed —
  # a change the reference suite says must move it.
  defp tagging(resource, body, previous, options) do
    _ = {resource, previous, options}

    if scheduling_body?(body) do
      {:set, schedule_tag(), fresh_tag(body)}
    else
      {:remove, schedule_tag()}
    end
  end

  defp schedule_tag, do: {Xml.caldav(), "schedule-tag"}

  defp schedule_etags, do: {Xml.caldav(), "schedule-etags"}

  # RFC 6638 section 3.2.10: applying another attendee's reply moves
  # the `ETag` without moving the `Schedule-Tag`, and every `ETag`
  # accumulated since the tag last changed still satisfies `If-Match`
  # — the client's copy is stale only in ways it never agreed to.
  # Each internal write appends its result to the ledger; a client
  # write, or a fresh delivery, starts it over.
  defp noted_etag(object, %{store: store, context: context}) do
    with true <- Store.supports?(store, :patch) and Store.supports?(store, :properties),
         {:ok, fresh} <- store.resolve(object.path, context),
         etag when is_binary(etag) <- fresh.etag do
      known =
        case Map.get(store.properties(fresh, context) || %{}, schedule_etags()) do
          listed when is_binary(listed) -> String.split(listed, " ")
          _none -> []
        end

      tags = Enum.uniq(known ++ [etag])
      store.patch(fresh, [{:set, schedule_etags(), Enum.join(tags, " ")}], context)
    end

    :ok
  end

  defp reset_etags(resource, body, %{store: store, context: context}) do
    with true <- scheduling_body?(body),
         {:ok, fresh} <- store.resolve(resource.path, context),
         etag when is_binary(etag) <- fresh.etag do
      [{:set, schedule_etags(), etag}]
    else
      _not_scheduling -> [{:remove, schedule_etags()}]
    end
  end

  defp scheduling_body?(body) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar) do
      not is_nil(organizer_of(components)) and attendees_of(components) != []
    else
      _not_scheduling -> false
    end
  end

  # An absent `PARTSTAT` *is* `NEEDS-ACTION` — RFC 5545 says so — and
  # the server writes the default out where a client left it implied.
  # Comparing the two spellings as different made every write look
  # like a change of participation.
  defp comparable(parameters) do
    parameters
    |> Map.drop(["CN", "EMAIL", "X-CALENDARSERVER-RESET-PARTSTAT" | @maintained])
    |> Map.put_new("PARTSTAT", "NEEDS-ACTION")
  end

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

    tag ++
      default_calendar(resource, options) ++
      free_busy_set(resource, options) ++
      calendar_transparency(resource, options) ++
      timezone_identifier(resource, options) ++
      collection_tag(resource, options) ++ member_post(resource, options)
  end

  # RFC 5995: where a client may `POST` a new member without naming
  # it. A calendar offers one; its home does not — collections are not
  # created this way.
  defp member_post(resource, _options) do
    if Cal.calendar?(resource),
      do: [{{Xml.dav(), "add-member"}, {:hrefs, [Resource.href(resource) <> ";add-member"]}}],
      else: []
  end

  # `CS:getctag` — the collection change tag Apple's clients poll
  # before deciding whether to look closer. It moves exactly when the
  # synchronisation token does, because they answer the same question.
  defp collection_tag(resource, %{store: store, context: context}) do
    case Store.supports?(store, :sync_token) and store.sync_token(resource, context) do
      token when is_binary(token) ->
        [{{"http://calendarserver.org/ns/", "getctag"}, token}]

      _not_synchronised ->
        []
    end
  end

  # RFC 7809 section 7: `CALDAV:calendar-timezone-id` is the other
  # spelling of `CALDAV:calendar-timezone` — one names the zone, the
  # other carries its definition, and the pair must agree. A calendar
  # holding only the definition still answers for the identifier.
  defp timezone_identifier(resource, %{store: store, context: context}) do
    with true <- Cal.calendar?(resource),
         true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context),
         :error <- Map.fetch(properties, {Xml.caldav(), "calendar-timezone-id"}),
         value when is_binary(value) <-
           Map.get(properties, {Xml.caldav(), "calendar-timezone"}),
         [_line, zone] <- Regex.run(~r/^TZID:(.+)$/m, value) do
      [{{Xml.caldav(), "calendar-timezone-id"}, String.trim(zone)}]
    else
      _stated_or_not_a_calendar -> []
    end
  end

  # RFC 6638 section 9.1: every calendar answers whether its events
  # count toward the owner's free-busy time. The default is opaque; a
  # value the deployment stored stands on its own.
  defp calendar_transparency(resource, options) do
    if Cal.calendar?(resource) and is_nil(stored_transparency(resource, options)) do
      [{{Xml.caldav(), "schedule-calendar-transp"}, {:names, [{Xml.caldav(), "opaque"}]}}]
    else
      []
    end
  end

  defp stored_transparency(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context) do
      Map.get(properties, {Xml.caldav(), "schedule-calendar-transp"})
    else
      _none -> nil
    end
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

  @doc """
  Whether a property instruction may be applied.

  RFC 4791 section 6.2.1: `CALDAV:calendar-free-busy-set` names the
  calendars consulted for the owner's free-busy time. A set naming a
  collection that does not exist — or is not a calendar — describes a
  consultation that can never happen, and the reference refuses the
  write rather than storing it. The property may be replaced but not
  removed.

  ### Arguments

  * `resource` is the resource being patched.

  * `instruction` is one parsed instruction, `{:set, qname, value}`
    or `{:remove, qname}`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok` for any property this hook gives no semantics to, and for a
    valid free-busy set.

  * `{:error, qname}` for a free-busy set naming anything but
    existing calendars, or an attempt to remove it.

  """
  @impl Dav.Web.Hook
  @spec patchable(Resource.t(), {:set, Xml.qname(), term()} | {:remove, Xml.qname()}, map()) ::
          :ok | {:error, Xml.qname()}
  def patchable(_resource, {:remove, {ns, "calendar-free-busy-set"} = name}, _options)
      when ns == "urn:ietf:params:xml:ns:caldav",
      do: {:error, name}

  def patchable(_resource, {:set, {ns, "calendar-free-busy-set"} = name, value}, options)
      when ns == "urn:ietf:params:xml:ns:caldav" do
    case value do
      {:hrefs, hrefs} ->
        if Enum.all?(hrefs, &calendar_href?(&1, options)), do: :ok, else: {:error, name}

      _not_a_set_of_hrefs ->
        {:error, name}
    end
  end

  def patchable(_resource, {:set, {ns, "schedule-default-calendar-URL"} = name, value}, options)
      when ns == "urn:ietf:params:xml:ns:caldav" do
    # RFC 6638 section 9.2, sharpened the way the reference does: the
    # default calendar is where *your* invitations land, and a
    # calendar shared into your home belongs to somebody else —
    # deliveries into it would put your meetings on their calendar.
    case value do
      {:hrefs, [href]} ->
        if own_calendar_href?(href, options), do: :ok, else: {:error, name}

      _not_one_href ->
        {:error, name}
    end
  end

  def patchable(_resource, _instruction, _options), do: :ok

  defp own_calendar_href?(href, %{store: store, context: context}) do
    with path when path != [] <- String.split(href, "/", trim: true),
         {:ok, %Resource{} = found} <- store.resolve(path, context),
         true <- Cal.calendar?(found) do
      not Store.supports?(store, :origin) or store.origin(found.path, context) == found.path
    else
      _missing_or_not_a_calendar -> false
    end
  end

  defp calendar_href?(href, %{store: store, context: context}) do
    with path when path != [] <- String.split(href, "/", trim: true),
         {:ok, %Resource{} = found} <- store.resolve(path, context) do
      Cal.calendar?(found)
    else
      _missing -> false
    end
  end

  @doc """
  Repair the default-calendar pointer after a move.

  A calendar that is somebody's scheduling default does not stop
  being it by being renamed: the stored
  `CALDAV:schedule-default-calendar-URL` on their Inbox followed the
  old address and is rewritten to the new one.

  ### Arguments

  * `source` is the path the resource was moved from.

  * `destination` is the path it now lives at.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, always.

  """
  @impl Dav.Web.Hook
  @spec relocated([String.t()], [String.t()], map()) :: :ok
  def relocated(source, destination, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :patch),
         {:ok, %Resource{} = landed} <- store.resolve(destination, context),
         true <- Cal.calendar?(landed),
         {:ok, home} <- store.resolve(Enum.drop(source, -1), context),
         %Resource{} = inbox <- collection(home, &Schedule.inbox?/1, options),
         {:hrefs, [held]} <- stored_default(inbox, options),
         true <- String.trim_trailing(held, "/") == "/" <> Enum.join(source, "/") do
      instruction =
        {:set, {Xml.caldav(), "schedule-default-calendar-URL"}, {:hrefs, [Resource.href(landed)]}}

      store.patch(inbox, [instruction], context)
      :ok
    else
      _not_the_default -> :ok
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
         nil <- stored_default(resource, options) do
      case first_calendar(resource, options) do
        %Resource{} = calendar ->
          [{{Xml.caldav(), "schedule-default-calendar-URL"}, {:hrefs, [Resource.href(calendar)]}}]

        nil ->
          # The property outlives its calendar: a home whose last
          # calendar was deleted still answers, with nothing in it,
          # until a delivery provisions a new default.
          [{{Xml.caldav(), "schedule-default-calendar-URL"}, nil}]
      end
    else
      _not_an_inbox_or_stated -> []
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
    case ICalendar.parse(body) do
      {:ok, parsed} ->
        calendar = normalised(resource, parsed, options)

        with [_ | _] = components <- schedulable(calendar),
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
          # person's private appointment, and nobody needs telling —
          # but what was stored is still rewritten in the server's own
          # spelling (the *normalised* copy, repairs included), so a
          # client reads back what the server understood rather than
          # what it happened to send. Unless it *was* one: the
          # reference treats overwriting a scheduling object with
          # plain calendar data as a removal (`implicit.py`, existing
          # "schedule" against new "calendar" gives
          # `action = "remove"`), and the attendees are cancelled
          # from the old content.
          _nothing_to_schedule ->
            unscheduled_write(resource, collection, calendar, body, change, options)
        end

      _unreadable ->
        :ok
    end

    # Stamped last: the tag ledger records the `ETag` the client will
    # see, and delivery has just rewritten the body it hashes.
    stamp_schedule_tag(change, options)
    :ok
  end

  defp unscheduled_write(resource, collection, calendar, body, change, options) do
    case restored_scheduling(calendar, change, options) do
      {:ok, repaired, components, organizer} ->
        deliver(resource, collection, repaired, components, organizer, change, options)

      :plain ->
        unscheduled(change, collection, options)
        restated_body(resource, body, calendar, options)
    end
  end

  # A to-do client that lost the scheduling properties is repaired,
  # not obeyed. A PUT over a scheduled `VTODO` whose body keeps the
  # `UID` but has misplaced its `ORGANIZER` and `ATTENDEE` lines is
  # data loss, not a decision — the reference dresses the component
  # back in the stored lines and schedules as usual, and completing
  # the to-do marks the writer's own line `COMPLETED` on the way
  # through. Events stay strict: overwriting a scheduled `VEVENT`
  # with plain data is the removal the reference makes it.
  defp restored_scheduling(calendar, %{previous: previous}, options)
       when is_binary(previous) do
    with true <-
           Enum.all?(calendar.components, &(&1.name in ~w(VTODO VTIMEZONE))),
         {:ok, before} <- ICalendar.parse(previous),
         [_ | _] = held <- schedulable(before),
         organizer when is_binary(organizer) <- organizer_of(held),
         uid when is_binary(uid) <- Enum.find_value(held, &value(&1, "UID")),
         true <- Enum.any?(calendar.components, &(value(&1, "UID") == uid)) do
      writer = writer_addresses(options)

      repaired = %{
        calendar
        | components: Enum.map(calendar.components, &redressed(&1, held, writer))
      }

      case schedulable(repaired) do
        [_ | _] = schedulable -> {:ok, repaired, schedulable, organizer}
        _still_plain -> :plain
      end
    else
      _plain_overwrite -> :plain
    end
  end

  defp restored_scheduling(_calendar, _change, _options), do: :plain

  defp redressed(component, held, writer) do
    with false <- component.name == "VTIMEZONE",
         %{} = counterpart <- Enum.find(held, &(utc_rid(&1) == utc_rid(component))) do
      component |> reclothed(counterpart) |> completed_by(writer)
    else
      _zone_or_new -> component
    end
  end

  defp reclothed(component, counterpart) do
    missing =
      for property <- counterpart.properties,
          property.name in ~w(ORGANIZER ATTENDEE),
          not Enum.any?(component.properties, &(&1.name == property.name)),
          do: property

    %{component | properties: component.properties ++ missing}
  end

  # RFC 5545 section 3.8.1.1: a to-do is done when it says so.
  # `COMPLETED`, `STATUS:COMPLETED` or a hundred percent all mean the
  # writer finished it, and their own line records the answer.
  defp completed_by(component, writer) do
    if component.name == "VTODO" and done?(component) do
      %{component | properties: Enum.map(component.properties, &finished_line(&1, writer))}
    else
      component
    end
  end

  defp finished_line(%{name: "ATTENDEE", value: value} = property, writer) do
    if value in writer,
      do: %{property | parameters: Map.put(property.parameters, "PARTSTAT", "COMPLETED")},
      else: property
  end

  defp finished_line(property, _writer), do: property

  defp done?(component) do
    not is_nil(value(component, "COMPLETED")) or value(component, "STATUS") == "COMPLETED" or
      value(component, "PERCENT-COMPLETE") == "100"
  end

  defp writer_addresses(%{store: store, context: context} = options) do
    with who when is_binary(who) <- Map.get(options, :principal),
         true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(who, context) do
      Enum.map(addresses, &canonical_address(&1, options))
    else
      _unknown_writer -> []
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
    # A message is not the event. Clearing a scheduling Inbox throws
    # away invitations and replies that have already been applied to
    # the calendar copy — doing it must not decline anything, and a
    # server that replies to every `DELETE` in an Inbox answers on the
    # recipient's behalf each time their client tidies up.
    with false <- Schedule.inbox?(collection),
         {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar),
         organizer when not is_nil(organizer) <- organizer_of(components),
         addresses when addresses != [] <- owner_addresses(collection, options) do
      withdraw(calendar, components, organizer, addresses, options)
    else
      _nothing_to_schedule -> :ok
    end
  end

  defp unscheduled(%{previous: previous}, collection, options) when is_binary(previous) do
    with false <- Schedule.inbox?(collection),
         {:ok, calendar} <- ICalendar.parse(previous),
         [_ | _] = components <- schedulable(calendar),
         organizer when not is_nil(organizer) <- organizer_of(components),
         addresses when addresses != [] <- owner_addresses(collection, options) do
      withdraw(calendar, components, organizer, addresses, options)
    else
      _was_not_scheduling -> :ok
    end
  end

  defp unscheduled(_change, _collection, _options), do: :ok

  defp withdraw(calendar, components, organizer, addresses, options) do
    zones = zones(calendar)

    if organizer in addresses do
      # The organiser withdrew the event, so it is cancelled for
      # everyone else.
      recipients = Enum.reject(attendees_of(components), &(&1 in addresses))

      # The reference server numbers this in two steps — worth naming,
      # because the result looks arbitrary from outside. The remove
      # itself bumps the calendar ("CANCEL always bumps sequence",
      # `implicit.py`), and `generateCancel` then adds one more on the
      # way out, assuming the value it was handed is not final. An
      # event deleted while unnumbered is withdrawn at `SEQUENCE:2`.
      # A whole event withdraws as its master alone — RFC 5546's
      # CANCEL for the series; the reference's `generateCancel` with
      # no instances builds exactly this, and a message that also
      # carried the overrides would read as a stack of instance
      # cancellations. An event with no master travels as it is.
      cancelled =
        components
        |> bumped(components)
        |> Enum.map(&outgoing/1)
        |> whole_series()

      send_to(recipients, "CANCEL", cancelled, zones, options, every(cancelled))
      :ok
    else
      # An attendee removing their copy is declining. The reply carries
      # their own line with `PARTSTAT=DECLINED`, which is how the
      # organiser learns they are not coming rather than simply never
      # hearing back. Unless the organiser schedules through their own
      # client (`SCHEDULE-AGENT=CLIENT`/`NONE`): this server never
      # delivered for that meeting and does not start now.
      if organizer_delivers?(components),
        do: decline(components, organizer, addresses, zones, options),
        else: :ok
    end
  end

  # An attendee who already declined has nothing new to say by deleting
  # their copy, and a second identical reply is noise in the
  # organiser's Inbox. A *cancelled* copy is the same silence from the
  # other side: the organiser called the meeting off, and tidying the
  # strikethrough away declines nothing.
  defp whole_series(components) do
    case Enum.find(components, &is_nil(value(&1, "RECURRENCE-ID"))) do
      nil -> components
      master -> [master]
    end
  end

  defp decline(components, organizer, addresses, zones, options) do
    if already_declined?(components, addresses) or Enum.all?(components, &cancelled?/1) do
      :ok
    else
      declined = for component <- components, do: declined(only(component, addresses), addresses)

      send_to([organizer], "REPLY", declined, zones, options, every(declined))
      :ok
    end
  end

  # Declined the *whole* event, not one Tuesday of it. Somebody who
  # turned down a single instance is still coming to the rest, and
  # dropping them from every later message leaves their copy of the
  # series frozen at the version they answered.
  defp forced(components, options) do
    for component <- components,
        property <- component.properties,
        property.name == "ATTENDEE",
        Map.get(property.parameters, "SCHEDULE-FORCE-SEND") == "REQUEST",
        uniq: true,
        do: canonical_address(property.value, options)
  end

  defp unforced(%{name: "VTIMEZONE"} = zone), do: zone

  defp unforced(component) do
    properties =
      Enum.map(component.properties, fn property ->
        %{property | parameters: Map.delete(property.parameters, "SCHEDULE-FORCE-SEND")}
      end)

    %{component | properties: properties}
  end

  defp reasked_by_force(component, [], _options), do: component
  defp reasked_by_force(%{name: "VTIMEZONE"} = zone, _reinvited, _options), do: zone

  defp reasked_by_force(component, reinvited, options) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE" and
             canonical_address(property.value, options) in reinvited do
          parameters =
            property.parameters
            |> Map.put("PARTSTAT", "NEEDS-ACTION")
            |> Map.put("RSVP", "TRUE")
            |> Map.delete("SCHEDULE-STATUS")

          %{property | parameters: parameters}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  defp declined?(components, address) do
    Enum.all?(components, fn component ->
      Enum.any?(component.properties, fn property ->
        property.name == "ATTENDEE" and property.value == address and
          Map.get(property.parameters, "PARTSTAT") == "DECLINED"
      end)
    end)
  end

  defp cancel_lost(false, _components, _change, _addresses, _calendar, _options, _sent), do: []

  defp cancel_lost(true, components, change, addresses, calendar, options, sent) do
    # An instance already travelling in the exclusion cancellation is
    # not sent a second time as a loss. Whoever was messaged here was
    # delivered to this round, and their line restamps like any other.
    told =
      for {people, instances} <- uninvited(components, change, addresses),
          remaining = Enum.reject(instances, &(&1 in rids_of(sent))),
          remaining != [],
          lost = lost_instances(change, remaining),
          lost != [] do
        send_to(people, "CANCEL", lost, zones(calendar), options, every(lost))
        people
      end

    told |> List.flatten() |> Enum.uniq()
  end

  # The cancellation describes the meeting they had, not the one that
  # replaced it. The reference builds it from the *old* calendar
  # (`generateCancel(self.oldcalendar, ...)`): the override they were
  # in, at the time it was held at, its version raised by one on the
  # way out. Sending the new components instead names instances the
  # recipient never held — and a master among them reads as
  # withdrawing the whole series.
  defp lost_instances(%{previous: previous}, rids) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} -> withdrawn_from(schedulable(before), rids)
      _unreadable -> []
    end
  end

  defp lost_instances(_change, _rids), do: []

  defp withdrawn_from(held, rids) do
    master = Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID")))

    if nil in rids do
      withdrawn_series(master)
    else
      for rid <- rids,
          component = held_instance(held, master, rid),
          do: outgoing(component)
    end
  end

  # A cancellation of the whole series carries the old master itself,
  # rule and all — the recipient's copy is struck through in one
  # stroke.
  defp withdrawn_series(nil), do: []
  defp withdrawn_series(master), do: [outgoing(master)]

  defp held_instance(held, master, rid) do
    Enum.find(held, &(value(&1, "RECURRENCE-ID") == rid)) || derived_lost(master, rid)
  end

  defp derived_lost(nil, _rid), do: nil

  defp derived_lost(master, rid) do
    derived_instance(master, rid_zone(master), rid)
  end

  defp rid_zone(master) do
    case Enum.find(master.properties, &(&1.name == "DTSTART")) do
      %{parameters: parameters} -> Map.take(parameters, ["TZID"])
      _no_start -> %{}
    end
  end

  defp uninvited(components, %{previous: previous}, addresses) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} -> lost(schedulable(before), components, addresses)
      _unreadable -> []
    end
  end

  defp uninvited(_components, _change, _addresses), do: []

  defp invited(components) do
    Map.new(components, &{value(&1, "RECURRENCE-ID"), attendees_of([&1])})
  end

  defp lost(held, components, addresses) do
    master = Enum.find(components, &is_nil(value(&1, "RECURRENCE-ID")))

    if reasked?(master, held),
      do: lost_to_reschedule(held, master, addresses),
      else: lost_by_instance(held, components, addresses)
  end

  # A reschedule redraws the whole series, and there is no guaranteed
  # mapping between old and new instances. The reference's rule
  # (`findRemovedAttendeesOnRecurrenceChange`): anyone in the new
  # master sees a replacement, never a cancel; anyone else is sent a
  # cancel for the master — the whole old series — or for each old
  # override that named them.
  defp lost_to_reschedule(held, master, addresses) do
    invited_now = attendees_of([master])

    losses =
      for component <- held,
          address <- attendees_of([component]),
          address not in addresses,
          address not in invited_now,
          reduce: %{} do
        found ->
          Map.update(found, address, [value(component, "RECURRENCE-ID")], fn instances ->
            [value(component, "RECURRENCE-ID") | instances]
          end)
      end

    losses
    |> Enum.map(fn {address, instances} ->
      {address, if(nil in instances, do: [nil], else: Enum.sort(instances))}
    end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.map(fn {instances, people} -> {people, instances} end)
  end

  defp lost_by_instance(held, components, addresses) do
    now = invited(components)
    before = invited(held)
    series = Map.get(before, nil, [])

    # Every occurrence either side describes: one the organiser has
    # stopped naming, and one they have just started naming. The
    # second is the case an override introduces — before it existed
    # the recurrence rule covered that date, and whoever the rule
    # invited was invited to it.
    instances = (Map.keys(before) ++ Map.keys(now)) |> Enum.uniq() |> Enum.reject(&is_nil/1)

    losses =
      for instance <- instances,
          address <- Map.get(before, instance, series),
          address not in addresses,
          address not in Map.get(now, instance, Map.get(now, nil, [])),
          reduce: %{} do
        found -> Map.update(found, address, [instance], &[instance | &1])
      end

    losses
    |> Enum.group_by(fn {_address, held_instances} -> Enum.sort(held_instances) end, &elem(&1, 0))
    |> Enum.map(fn {held_instances, people} -> {people, held_instances} end)
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

  # A creation whose body already carries a version is a *restore*: the
  # organiser deleted the event and is putting it back, and the
  # attendees may still hold the cancellation, numbered wherever it
  # was. The reference server (`implicit.py`) forces the sequence "to a
  # new value that is significantly higher than the highest one
  # present" — `maxseq + 1000` — so the restored invitation outranks
  # any cancellation in flight, and this does the same.
  defp sequenced(components, %{previous: nil}) do
    case Enum.max(Enum.map(components, &sequence_number/1)) do
      0 -> components
      maxseq -> Enum.map(components, &restored(&1, maxseq + 1000))
    end
  end

  # An event that only now gained an organiser and attendees is being
  # *created* as a scheduling object, whatever the resource's history:
  # the reference decides create-versus-modify by whether the old data
  # was a scheduling object, and a create numbers nothing.
  defp sequenced(components, %{previous: previous} = change) do
    if scheduling_body?(previous),
      do: revised_sequence(components, previous),
      else: sequenced(components, %{change | previous: nil})
  end

  defp revised_sequence(components, previous) do
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
        property.name in names,
        into: MapSet.new(),
        do: {property.name, property.value}
  end

  # One number for the whole object. The reference bumps `SEQUENCE` on
  # every component at once — `maxSequence(old) + 1`, applied to all —
  # and only when the client left some component at or below its
  # stored counterpart's number (`needsiTIPSequenceChange`); a client
  # that raised every number is left alone. Before either test, no
  # number is allowed to go backwards (`sequenceInSync`).
  defp withdrawal_numbered(components, [], change) do
    if raised_by_client?(components, change),
      do: components,
      else: Enum.map(components, &outgoing/1)
  end

  defp withdrawal_numbered(components, _asked, _change), do: components

  # Whether the client's own save already raised every component's
  # number above its stored counterpart — `bumped/2`'s test, asked
  # without the correction.
  defp raised_by_client?(components, %{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)

        Enum.all?(
          components,
          &(&1.name == "VTIMEZONE" or renumbered?(&1, held))
        )

      _unreadable ->
        false
    end
  end

  defp raised_by_client?(_components, _change), do: false

  defp bumped(components, held) do
    components = in_sync(components, held)

    if Enum.any?(components, &(&1.name != "VTIMEZONE" and not renumbered?(&1, held))) do
      Enum.map(components, &restored(&1, top_sequence(held) + 1))
    else
      components
    end
  end

  defp renumbered?(component, held) do
    case counterpart_or_master_of(component, held) do
      nil -> true
      stored -> sequence_number(component) > sequence_number(stored)
    end
  end

  # The counterpart an instance is compared against. A new override
  # has no stored twin, so its version is measured against the master
  # it was carved from — the reference falls back the same way.
  defp counterpart_or_master_of(component, held) do
    counterpart(component, held) ||
      Enum.find(held, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))
  end

  defp top_sequence(components) do
    components
    |> Enum.filter(&(&1.name != "VTIMEZONE"))
    |> Enum.map(&sequence_number/1)
    |> Enum.max(fn -> 0 end)
  end

  defp in_step(components, %{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} -> in_sync(components, schedulable(before))
      _unreadable -> components
    end
  end

  defp in_step(components, _change), do: components

  defp in_sync(components, held) do
    floor = top_sequence(held)

    lowest =
      components
      |> Enum.filter(&(&1.name != "VTIMEZONE"))
      |> Enum.map(&sequence_number/1)
      |> Enum.min(fn -> 0 end)

    if floor > 0 and lowest < floor do
      Enum.map(components, &restored(&1, floor))
    else
      components
    end
  end

  # `generateCancel`'s own `seq + 1`, unconditional — unlike
  # `bumped/2`, which defers to a client that already raised the
  # number. Only the *delete* path wants it: there the reference
  # server generates the message from the copy it has just bumped, so
  # the two increments stack. A cancellation sent during a modify is
  # generated from the *old* copy, and its `old + 1` equals the number
  # the accompanying invitation already carries — applying this there
  # over-counts, measured −9.
  defp outgoing(%{name: "VTIMEZONE"} = zone), do: zone
  defp outgoing(component), do: restored(component, sequence_number(component) + 1)

  defp restored(%{name: "VTIMEZONE"} = zone, _sequence), do: zone

  defp restored(component, sequence) do
    stated = %{name: "SEQUENCE", parameters: %{}, value: "#{sequence}"}

    properties =
      Enum.reject(component.properties, &(&1.name == "SEQUENCE")) ++ [stated]

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
      # A line on a cancelled instance is not an answer — the occasion
      # it answered is off. Counting it made tidying a cancellation
      # away look like a change of heart, and sent the organiser a
      # reply about a meeting they had already withdrawn.
      for component <- components,
          not cancelled?(component),
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

  # A room that declined still receives its copy: the reference
  # writes the turned-down booking to the resource's calendar,
  # transparent, as the record of what was asked. A person who
  # declined by deleting theirs is left alone.
  defp silently_declined?(recipient, components, options) do
    declined?(components, recipient) and
      not still_holds?(recipient, components, options) and
      not auto_managed?(recipient, options)
  end

  # Which components the client's own body renumbered against the
  # stored copy — read raw, before any server-side syncing raises
  # anything.
  defp client_renumbered(%{body: body, previous: previous})
       when is_binary(body) and is_binary(previous) do
    with {:ok, sent} <- ICalendar.parse(body),
         {:ok, before} <- ICalendar.parse(previous) do
      held = schedulable(before)

      for component <- schedulable(sent),
          counterpart = Enum.find(held, &(recurrence(&1) == recurrence(component))),
          counterpart != nil,
          sequence_number(component) > sequence_number(counterpart),
          do: utc_rid(component)
    else
      _unreadable -> []
    end
  end

  defp client_renumbered(_change), do: []

  defp prepared(components, change, options) do
    components =
      components
      |> Enum.map(&remembered(&1, change, options))
      |> Enum.map(fn component ->
        %{component | properties: Enum.map(component.properties, &promoted/1)}
      end)
      |> Enum.map(&once_each/1)

    components ++
      (components |> revived(change, options) |> Enum.map(&remembered(&1, change, options)))
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
      options =
        Map.put(
          options,
          :series_master,
          Enum.find(components, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))
        )

      components = prepared(components, change, options)
      components = compacted(components, change, options)
      {components, auto_replied} = auto_answers(components, options)

      options =
        options
        |> Map.put(
          :auto_replied,
          Enum.map(Map.keys(auto_replied), &canonical_address(&1, options))
        )
        |> Map.put(
          :auto_master_answered,
          for(
            {address, %{master_changed: true}} <- auto_replied,
            do: canonical_address(address, options)
          )
        )
        |> Map.put(:client_renumbered, client_renumbered(change))

      delivering? = organizer_delivers?(components)

      recipients =
        if delivering? do
          # Somebody who declined but *kept* the event still hears when
          # the organiser edits it: the copy is on their calendar and
          # should stay current — they are entitled to know the thing
          # they turned down has been renamed or moved. Somebody who
          # declined by deleting their copy has taken it off their
          # calendar, and sending the edit would put it back.
          Enum.reject(attendees_of(components), &(&1 in addresses))
        else
          []
        end

      # Nothing is sent when nothing the attendees can see has changed.
      # An organiser adjusting their own alarm would otherwise put a
      # fresh invitation in every attendee's Inbox, asking them to
      # look at an event that is exactly as they left it.
      #
      # The no-copy decliners are dropped from *delivery* only:
      # `recipients` still names them, so the organiser's copy stamps
      # them `SCHEDULE-STATUS=1.2` like everyone else — the reference
      # does the same, holding their copy hidden rather than gone.
      # RFC 6638 section 7.1: `SCHEDULE-FORCE-SEND=REQUEST` re-invites
      # without changing anything — the named attendees are asked
      # again, their answers reset, and the parameter is consumed by
      # the send rather than stored or forwarded (the reference clears
      # it after scheduling and resets `PARTSTAT` the same way).
      reinvited = Enum.reject(forced(components, options), &(&1 in addresses))

      components =
        components |> Enum.map(&unforced/1) |> Enum.map(&reasked_by_force(&1, reinvited, options))

      options = Map.put(options, :reinvited, reinvited)

      # Numbers never go backwards, told or not: the reference runs
      # `sequenceInSync` on every modify, before it even asks whether
      # the change is worth announcing — and the comparison below is
      # of the *synced* copy, so a save that merely lowered `SEQUENCE`
      # is a save that changed nothing.
      components = in_step(components, change)

      asked =
        recipients
        |> Enum.reject(&silently_declined?(&1, components, options))
        |> notified(components, change, options)

      told = Enum.uniq(asked ++ reinvited)

      # And the version rises exactly when somebody is told. Raised
      # here and not before, because `SEQUENCE` is the organiser's own
      # numbering: an attendee declining one instance adds an
      # `EXDATE`, which looks like a change to the timing and had them
      # advancing it on the organiser's behalf.
      components = if asked == [], do: components, else: sequenced(components, change)

      # RFC 5546 section 3.2.5: a withdrawn instance travels as a
      # `CANCEL`, not as a `REQUEST` carrying `STATUS:CANCELLED` — and
      # not as an `EXDATE` the recipient is left to interpret. An
      # organiser excluding a date has called that occurrence off, so
      # each newly added exclusion becomes a derived instance in the
      # cancellation, built from the master the way the reference's
      # `generateCancel` builds one.
      withdrawn =
        Enum.filter(components, &cancelled?/1) ++ called_off(components, change)

      # The cancellation travels first. When both arrive, "a date this
      # copy already excludes" must mean the recipient's own exclusion
      # — the organiser's, arriving in the update, would otherwise be
      # mistaken for it, and the strikethrough never appears.
      # It goes to whoever held the withdrawn instances — a round that
      # asks nothing else still tells them, and their line restamps
      # with the delivery.
      cancel_told =
        Enum.uniq(told ++ Enum.reject(attendees_of(withdrawn), &(&1 in addresses)))

      send_to(cancel_told, "CANCEL", withdrawn, zones(calendar), options, every(withdrawn))

      # An attendee dropped from one occurrence has not been dropped
      # from the series: they keep the rest and are told about the one
      # they have lost. `departed/3` compares whole attendee lists and
      # cannot see it — from its point of view they are still invited.
      # This travels with the other cancellations, before the update:
      # a recipient losing the old series and gaining one instance of
      # the new must not have the new instance struck through by a
      # cancellation that was really about the old.
      lost_told =
        cancel_lost(delivering?, components, change, addresses, calendar, options, withdrawn)

      # What the cancellation already said is not asked again. A save
      # whose only news *is* the withdrawal — a `STATUS:CANCELLED`, an
      # instance excluded, nothing else touched — sends the `CANCEL`
      # alone; announcing it again in a `REQUEST` delivers the meeting
      # back to the person it was just taken from. A save that also
      # *changes* something still sends both.
      asking? = not (withdrawn != [] and only_cancellation?(change, options))

      refused =
        if asking? do
          send_to(
            told,
            "REQUEST",
            components,
            zones(calendar),
            Map.put(options, :created, created(components, change)),
            announced(components, change, options)
          )
        else
          []
        end

      # Anyone dropped from the invitation is told it is off. They are
      # no longer in the attendee list, so nothing else would reach
      # them — and an event they were invited to would sit in their
      # calendar for ever, with no way to learn it had moved on
      # without them.
      # An organiser whose client does its own scheduling is not
      # delivered for at all — cancellations included. Withdrawing an
      # invitation the server never sent would be the first the
      # recipient heard of the meeting.
      dropped = if delivering?, do: departed(components, change, addresses), else: []

      # `generateCancel`'s `seq + 1` for the withdrawn invitation.
      # When somebody was asked this round the components already rose
      # by one, and a client that renumbered its own save has done the
      # raising itself — either way the number is right as it stands.
      # Only when nobody raised it does the cancellation do so.
      withdrawal = withdrawal_numbered(components, asked, change)

      send_to(dropped, "CANCEL", withdrawal, zones(calendar), options, every(withdrawal))

      record(
        resource,
        organizer_stated(restated(calendar, components)),
        stamped_for(
          asked,
          Enum.uniq(dropped ++ lost_told ++ (cancel_told -- told)),
          reinvited,
          recipients
        ) -- refused,
        refused,
        options
      )
    else
      reply(resource, calendar, components, organizer, addresses, change, options)
    end
  end

  # A series whose only scheduling is in an override — the master
  # names nobody, one instance carries the invitation — still has one
  # organiser, and the reference writes it onto the master so the
  # object says whose event it is. The master gains no attendees: the
  # series itself invites no one.
  defp organizer_stated(calendar) do
    organizer =
      Enum.find_value(calendar.components, fn component ->
        if component.name != "VTIMEZONE",
          do: Enum.find(component.properties, &(&1.name == "ORGANIZER"))
      end)

    components =
      Enum.map(calendar.components, fn component ->
        if component.name != "VTIMEZONE" and is_nil(value(component, "RECURRENCE-ID")) and
             not is_nil(organizer) and
             not Enum.any?(component.properties, &(&1.name == "ORGANIZER")) do
          %{component | properties: component.properties ++ [organizer]}
        else
          component
        end
      end)

    %{calendar | components: components}
  end

  defp with_master(calendar, components, organizer, addresses, options) do
    with [_ | _] <- components,
         true <- Enum.all?(components, &value(&1, "RECURRENCE-ID")),
         address when is_binary(address) <- Enum.find(addresses, & &1),
         %{} = master <- organizers_master(components, organizer, options),
         true <- invited_to_series?(master, addresses, options) do
      restored =
        master
        |> stamp([], options)
        |> unstamped()
        |> without_alarms()
        |> unagented()
        |> unextended(extensions(options))
        |> transparent_until_answered(canonical_address(address, options))

      %{calendar | components: [restored | calendar.components]}
    else
      _has_master_or_nothing_to_restore -> calendar
    end
  end

  # Only somebody invited to the *series* gets the series back. An
  # attendee named on one occurrence holds that occurrence: their copy
  # having no master is correct, not damage.
  defp invited_to_series?(master, addresses, options) do
    canonical = Enum.map(addresses, &canonical_address(&1, options))

    Enum.any?(master.properties, fn property ->
      property.name == "ATTENDEE" and canonical_address(property.value, options) in canonical
    end)
  end

  defp organizers_master(components, organizer, options) do
    uid = Enum.find_value(components, &value(&1, "UID"))

    with true <- hosted?(organizer, options),
         %Resource{} = home <- home_of(organizer, options),
         scoped = as(home, options),
         %Resource{} = collection <- collection(home, &event_calendar?(&1, scoped), scoped),
         %Resource{} = object <- object_with(collection, uid, scoped),
         {:ok, body} <- read(object, scoped),
         {:ok, stored} <- ICalendar.parse(body) do
      Enum.find(schedulable(stored), &is_nil(value(&1, "RECURRENCE-ID")))
    else
      _unreachable -> nil
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
  defp untaken(%{name: name} = component, _recipient) when name != "VEVENT", do: component

  defp untaken(component, recipient) do
    if needs_action?(component, recipient) do
      %{component | properties: transparent(component.properties)}
    else
      component
    end
  end

  # *Their* answer, not anybody's. A meeting where one other guest has
  # yet to reply still occupies the time of everyone who accepted, and
  # marking their copy transparent frees a slot they are committed to.
  defp needs_action?(component, recipient) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and property.value == recipient and
        Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION"
    end)
  end

  # A room answers the moment it is invited, and the server sends that
  # answer for it. Its copy records the delivery the same way any
  # attendee's does — without it, the room's own view of the meeting
  # never shows that the organiser heard back.
  defp replied(component, recipient) do
    if Enum.any?(component.properties, &room?(&1, recipient)),
      do: %{component | properties: Enum.map(component.properties, &heard/1)},
      else: component
  end

  defp room?(property, recipient) do
    property.name == "ATTENDEE" and property.value == recipient and
      unattended?(property.parameters)
  end

  defp heard(%{name: "ORGANIZER"} = property),
    do: %{property | parameters: Map.put(property.parameters, "SCHEDULE-STATUS", "1.2")}

  defp heard(property), do: property

  defp transparent(properties) do
    Enum.reject(properties, &(&1.name == "TRANSP")) ++
      [%{name: "TRANSP", parameters: %{}, value: "TRANSPARENT"}]
  end

  defp reply(resource, calendar, components, organizer, addresses, change, options) do
    # A copy that lost its master is repaired, not believed. A client
    # answering one occurrence sometimes sends *only* that occurrence,
    # and storing it as sent leaves the attendee holding one Tuesday of
    # a weekly series they are still invited to. The master is
    # restored from the organiser's copy, shaped as a delivery — their
    # own line back to `NEEDS-ACTION`, transparent until answered.
    # The reply itself still answers only what the client sent.
    {calendar, components, restored} =
      believed(calendar, components, organizer, addresses, change, options)

    cond do
      # A copy that is nothing but strikethroughs for instances it
      # never held is not a copy of anything. An attendee writing a
      # lone cancelled instance that was never theirs has stored no
      # meeting — the object is removed, and the next read is a 404
      # rather than a fabricated event.
      Enum.all?(components, &cancelled?/1) and
          not Enum.any?(components, &(utc_rid(&1) in held_rids(change))) ->
        remove(resource, options)

      # RFC 6638 section 3.2.9: "5.3" is "no scheduling support for
      # user". An organiser this server cannot reach, or a copy whose
      # attendee list does not name the person storing it, is one no
      # reply can be sent for — and the owner's client is told so on
      # the `ORGANIZER` rather than left waiting for a delivery that
      # will never happen.
      not answerable?(components, organizer, addresses, options) ->
        record_unschedulable(resource, calendar, organizer, options)

      organizer_delivers?(components) and answering?(change, components, addresses, options) ->
        # An `EXDATE` added with no other word *is* the answer: the
        # attendee has declined that instance, and the reply must say
        # so even though their own `PARTSTAT` never moved.
        # The reply carries what changed and nothing else — the
        # reference generates it from the changed instances alone. An
        # unanswered component echoed into it would stamp the
        # organiser's copy as though a question still open had been
        # processed.
        replies =
          components
          |> spoken_replies(restored, change, addresses, options)
          |> Enum.map(&confirmed/1)

        send_to([organizer], "REPLY", replies, zones(calendar), options, every(replies))
        record_reply(resource, calendar, organizer, addresses, change, options)

      true ->
        carry_reply(resource, calendar, organizer, addresses, change, options)
    end

    :ok
  end

  # Taking an occurrence out of your own copy is declining it. The
  # organiser is told so explicitly: the instance is gone from the
  # reply's own components, so without this the message says nothing
  # at all about the one thing that changed.
  defp repaired_transparency(calendar, components, %{previous: previous})
       when is_binary(previous) do
    sent_master? =
      Enum.any?(components, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    # Only a copy that *had* a master and lost it was repaired. An
    # instance-only copy never held one, and its saves speak for
    # themselves.
    with false <- sent_master?,
         {:ok, before} <- ICalendar.parse(previous),
         held = schedulable(before),
         %{} <- Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID"))) do
      %{calendar | components: Enum.map(calendar.components, &kept_transparency(&1, held))}
    else
      _spoke_for_itself -> calendar
    end
  end

  defp repaired_transparency(calendar, _components, _change), do: calendar

  defp kept_transparency(%{name: "VTIMEZONE"} = zone, _held), do: zone

  defp kept_transparency(component, held) do
    if Enum.any?(component.properties, &(&1.name == "TRANSP")),
      do: component,
      else: carry_transparency(component, held)
  end

  # The overrides a client's save dropped without excluding, restored
  # verbatim from the previous copy. Only a copy that keeps its
  # master qualifies — with no master, taking an instance out is the
  # decline it looks like.
  # RFC 5546 section 3.2.3: a `REPLY` reports how the request fared,
  # and the reference writes `2.0;Success` into every component it
  # answers with.
  defp confirmed(component) do
    stated = %{name: "REQUEST-STATUS", parameters: %{}, value: "2.0;Success"}
    %{component | properties: component.properties ++ [stated]}
  end

  # A repaired component answers too: the client's save touched it,
  # and the organiser hears the restored state — an unchanged
  # `PARTSTAT` with the reply's own request-status, the way the
  # reference replies for every rid the write covered.
  defp spoken_replies(components, restored, change, addresses, options) do
    spoken_rids = for component <- restored, do: utc_rid(component)

    for(
      component <- components,
      utc_rid(component) in spoken_rids or
        spoken_for?(component, change, addresses, options),
      do: only(component, addresses)
    ) ++
      withdrawn(change, components, addresses)
  end

  # What of the client's save is *believed*. A client that rewrote its
  # one instance as a master has lost the `RECURRENCE-ID`, not gained
  # a series, and the identifier goes back on (`re_identified`); a
  # copy that lost its master is repaired from the organiser's
  # (`with_master`); an override dropped without an `EXDATE` while
  # the master stays is put back verbatim — declining takes an
  # `EXDATE`, anything less is a client losing data
  # (`dropped_carelessly`); and the per-user `TRANSP` such a save
  # also dropped is restored rather than read as removal
  # (`repaired_transparency`, the reference's
  # `PerUserDataFilter.merge`).
  defp believed(calendar, components, organizer, addresses, change, options) do
    {calendar, components} = re_identified(calendar, components, change)

    calendar =
      calendar |> with_master(components, organizer, addresses, options) |> in_held_zones(change)

    restored = dropped_carelessly(change, components, options)
    components = components ++ restored

    calendar =
      %{calendar | components: calendar.components ++ restored}
      |> repaired_transparency(components, change)

    components = Enum.map(components, &public_restored(&1, change, options))

    calendar = %{
      calendar
      | components: Enum.map(calendar.components, &public_restored(&1, change, options))
    }

    {calendar, components, restored}
  end

  # A travelling `X-` property is the organiser's word about the
  # meeting, not the attendee's to erase: a save that omits one has
  # lost it, and the stored value goes back on. A *changed* value is
  # different — those travel, in both directions.
  defp public_restored(%{name: "VTIMEZONE"} = zone, _change, _options), do: zone

  defp public_restored(component, %{previous: previous}, options) when is_binary(previous) do
    allowed = extensions(options)

    with {:ok, before} <- ICalendar.parse(previous),
         %{} = counterpart <-
           Enum.find(schedulable(before), &(utc_rid(&1) == utc_rid(component))) do
      missing =
        for property <- counterpart.properties,
            travels?(property.name, allowed),
            not Enum.any?(component.properties, &(&1.name == property.name)),
            do: property

      %{component | properties: component.properties ++ missing}
    else
      _no_previous_word -> component
    end
  end

  defp public_restored(component, _change, _options), do: component

  defp re_identified(calendar, components, %{previous: previous}) when is_binary(previous) do
    with {:ok, before} <- ICalendar.parse(previous),
         [_ | _] = held <- schedulable(before),
         nil <- Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID"))) do
      {%{calendar | components: Enum.map(calendar.components, &re_identify(&1, held))},
       Enum.map(components, &re_identify(&1, held))}
    else
      _had_a_master -> {calendar, components}
    end
  end

  defp re_identified(calendar, components, _change), do: {calendar, components}

  defp re_identify(component, held) do
    with false <- component.name == "VTIMEZONE",
         nil <- value(component, "RECURRENCE-ID"),
         %{} = dtstart <- Enum.find(component.properties, &(&1.name == "DTSTART")),
         %{} = counterpart <-
           Enum.find(held, &(utc_rid(&1) == utc_form(dtstart.value, dtstart.parameters))),
         %{} = rid <- Enum.find(counterpart.properties, &(&1.name == "RECURRENCE-ID")) do
      %{component | properties: [rid | component.properties]}
    else
      _identified -> component
    end
  end

  # A merging write is stale, not careless: the client asked for
  # reconciliation, and the merge machinery restores what its copy
  # lacked — with the writer's own series answer applied, which a
  # verbatim restore would clobber.
  defp dropped_carelessly(%{merge: true}, _components, _options), do: []

  defp dropped_carelessly(%{previous: previous}, components, _options) when is_binary(previous) do
    master =
      Enum.find(components, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    with %{} <- master,
         {:ok, before} <- ICalendar.parse(previous) do
      kept = for component <- components, rid = utc_rid(component), is_binary(rid), do: rid
      gone = utc_exclusion_set(master)

      for component <- schedulable(before),
          rid = utc_rid(component),
          is_binary(rid),
          rid not in kept,
          rid not in gone,
          TimeRange.occurs?(master, rid_parameters(component), value(component, "RECURRENCE-ID")),
          do: component
    else
      _masterless_or_unreadable -> []
    end
  end

  defp dropped_carelessly(_change, _components, _options), do: []

  # Whether this save says anything the organiser must hear: an
  # answer, a withdrawn occurrence, or a change to the extensions
  # that travel.
  defp answering?(change, components, addresses, options) do
    answered?(change, addresses) or withdrawn(change, components, addresses) != [] or
      extensions_changed?(change, components, addresses, options) or
      cancelled_answered?(change, addresses)
  end

  # A line on a cancelled instance is no answer when it merely
  # disappears — but a client *changing* it is a person speaking: an
  # attendee declining a strikethrough they had accepted has said
  # something, and the reference carries it (the `answers/2` tally
  # skips cancelled components precisely because it compares absence,
  # not change).
  defp cancelled_answered?(%{body: body, previous: previous}, addresses)
       when is_binary(previous) do
    with {:ok, now} <- ICalendar.parse(body),
         {:ok, before} <- ICalendar.parse(previous) do
      held = schedulable(before)

      Enum.any?(schedulable(now), fn component ->
        cancelled?(component) and moved_answer?(component, held, addresses)
      end)
    else
      _unreadable -> false
    end
  end

  defp cancelled_answered?(_change, _addresses), do: false

  defp moved_answer?(component, held, addresses) do
    case Enum.find(held, &(utc_rid(&1) == utc_rid(component))) do
      nil -> false
      counterpart -> own_answer(component, addresses) != own_answer(counterpart, addresses)
    end
  end

  defp withdrawn(%{previous: previous} = change, components, addresses)
       when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        kept = MapSet.new(components, &value(&1, "RECURRENCE-ID"))

        removed = removed_declines(before, kept, change, addresses)

        removed ++ newly_excluded(components, change, addresses)

      _unreadable ->
        []
    end
  end

  defp withdrawn(_change, _components, _addresses), do: []

  # Whether this component says anything the previous copy did not —
  # the writer's own answer, or the extensions that travel. A copy
  # with no previous version speaks for everything it holds.
  defp spoken_for?(component, %{previous: previous}, addresses, options)
       when is_binary(previous) do
    allowed = extensions(options)

    case ICalendar.parse(previous) do
      {:ok, before} ->
        case Enum.find(schedulable(before), &(utc_rid(&1) == utc_rid(component))) do
          nil ->
            true

          counterpart ->
            own_answer(component, addresses) != own_answer(counterpart, addresses) or
              travelling_view(component, addresses, allowed) !=
                travelling_view(counterpart, addresses, allowed)
        end

      _unreadable ->
        true
    end
  end

  defp spoken_for?(_component, _change, _addresses, _options), do: true

  defp own_answer(component, addresses) do
    Enum.find_value(component.properties, fn property ->
      if property.name == "ATTENDEE" and property.value in addresses,
        do: Map.get(property.parameters, "PARTSTAT", "NEEDS-ACTION")
    end)
  end

  # Travelling extensions answer too. An attendee changing an `X-`
  # property or a public parameter on their own line has said
  # something the organiser's copy carries, and the reference replies
  # with it even though no `PARTSTAT` moved.
  defp extensions_changed?(%{previous: previous}, components, addresses, options)
       when is_binary(previous) do
    allowed = extensions(options)

    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)

        Enum.any?(components, &travelling_moved?(&1, held, addresses, allowed))

      _unreadable ->
        false
    end
  end

  defp extensions_changed?(_change, _components, _addresses, _options), do: false

  defp travelling_moved?(component, held, addresses, allowed) do
    case Enum.find(held, &(utc_rid(&1) == utc_rid(component))) do
      nil ->
        false

      counterpart ->
        travelling_view(component, addresses, allowed) !=
          travelling_view(counterpart, addresses, allowed)
    end
  end

  # What this writer's copy says through the extensions that travel:
  # the shared `X-` properties, and the public parameters on their own
  # `ATTENDEE` line.
  defp travelling_view(component, addresses, allowed) do
    properties =
      for property <- component.properties,
          travels?(property.name, allowed),
          do: {property.name, property.value}

    parameters =
      for property <- component.properties,
          property.name == "ATTENDEE",
          property.value in addresses,
          do: travelling(property.parameters, allowed)

    {Enum.sort(properties), parameters}
  end

  # A reschedule redraws the series, and an override that survived it
  # saying nothing the new master does not — same time, same words,
  # same freshly re-asked attendees — is no exception any more. The
  # expected copies carry only the master; keeping the ghost would
  # hand every recipient an override describing nothing.
  defp compacted(components, change, options) do
    master = Map.get(options, :series_master)

    with %{} <- master,
         true <- series_rescheduled?(change, master) do
      Enum.reject(components, fn component ->
        rid = value(component, "RECURRENCE-ID")

        is_binary(rid) and not cancelled?(component) and
          instance(component, options) ==
            instance(derived_instance(master, rid_parameters(component), rid), options)
      end)
    else
      _unchanged_series -> components
    end
  end

  defp series_rescheduled?(%{previous: previous}, master) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} -> reasked?(master, schedulable(before))
      _unreadable -> false
    end
  end

  defp series_rescheduled?(_change, _master), do: false

  # An organiser who deletes an override without excluding its date
  # has not cancelled the occurrence — the rule still produces it. The
  # reference compares the dropped override to an instance derived
  # from the new master and, when they differ, puts the derived
  # instance back so the change is announced rather than silently
  # forgotten (`coerceAttendeesPartstatOnModify`, the removals
  # branch). A redundant override — one that said nothing the master
  # does not — is simply gone.
  defp revived(components, %{previous: previous}, options) when is_binary(previous) do
    master =
      Enum.find(components, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    with %{} <- master,
         {:ok, before} <- ICalendar.parse(previous) do
      kept = MapSet.new(components, &value(&1, "RECURRENCE-ID"))
      gone = exclusions(master)

      for component <- schedulable(before),
          rid = value(component, "RECURRENCE-ID"),
          not is_nil(rid),
          rid not in kept,
          rid not in gone,
          not cancelled?(component),
          parameters = rid_parameters(component),
          TimeRange.occurs?(master, parameters, rid),
          derived = derived_instance(master, parameters, rid),
          meeting_view(derived, options) != meeting_view(component, options),
          do: derived
    else
      _no_master_or_unreadable -> []
    end
  end

  defp revived(_components, _change, _options), do: []

  # What the meeting *is*, apart from who has answered: participation
  # moves on its own schedule and does not make a dropped override
  # worth restoring.
  defp meeting_view(component, options) do
    for {name, address, parameters} <- instance(component, options),
        into: MapSet.new(),
        do: {name, address, Map.delete(parameters, "PARTSTAT")}
  end

  # A cancelled occurrence is not declined by tidying it away — the
  # organiser called it off, and deleting the strikethrough is
  # housekeeping. A merging write is stale, not spare: the client
  # asked for reconciliation, so an override its copy never showed is
  # restored rather than read as a refusal.
  defp removed_declines(_before, _kept, %{merge: true}, _addresses), do: []

  defp removed_declines(before, kept, _change, addresses) do
    for component <- schedulable(before),
        not cancelled?(component),
        not attendee_declined?(component, addresses),
        not is_nil(value(component, "RECURRENCE-ID")),
        value(component, "RECURRENCE-ID") not in kept,
        do: declined(only(component, addresses), addresses)
  end

  # An `EXDATE` the attendee adds withdraws an instance their copy
  # never held a component for — nothing disappears, so the removal
  # loop above cannot see it. The declined instance is derived from
  # their master, the same way a cancellation derives one, and the
  # organiser's copy then shows them `DECLINED` for that date.
  defp newly_excluded(components, change, addresses) do
    case Enum.find(components, &is_nil(value(&1, "RECURRENCE-ID"))) do
      nil ->
        []

      master ->
        for {parameters, instance} <- added_exclusions(master, change),
            instance not in already_off(change, addresses),
            do:
              declined(
                only(derived_instance(master, parameters, instance), addresses),
                addresses
              )
    end
  end

  # An `EXDATE` that tidies away an occurrence the organiser already
  # cancelled — or one this attendee already declined — withdraws
  # nothing: the answer on record does not move, and the organiser is
  # not told about the housekeeping.
  defp already_off(%{previous: previous}, addresses) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        for component <- schedulable(before),
            cancelled?(component) or attendee_declined?(component, addresses),
            rid = value(component, "RECURRENCE-ID"),
            not is_nil(rid),
            do: rid

      _unreadable ->
        []
    end
  end

  defp already_off(_change, _addresses), do: []

  defp attendee_declined?(component, addresses) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and property.value in addresses and
        Map.get(property.parameters, "PARTSTAT") == "DECLINED"
    end)
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
  defp record_reply(
         resource,
         calendar,
         organizer,
         addresses,
         change,
         %{store: store, context: context} = options
       ) do
    if Store.supports?(store, :put) do
      updated = %{
        calendar
        | components:
            (calendar.components ++ dropped_by_merge(calendar, change, addresses, options))
            |> Enum.map(&organizer_as_held(&1, change))
            |> Enum.map(&answered(&1, organizer))
            |> Enum.map(&others_restored(&1, change, addresses, options))
            |> Enum.map(&shareable(&1, extensions(options)))
      }

      store.put(resource.path, ICalendar.write(updated), @calendar_type, context)
    end

    :ok
  end

  # An attendee's copy carries the extensions that travel between
  # participants and no others. Whatever else their client hangs on the
  # event is private to it: keeping it here would make the attendee's
  # copy differ from the organiser's by data the organiser never sent
  # and cannot see, which is how two copies of one meeting stop
  # comparing equal.
  defp shareable(%{name: "VTIMEZONE"} = zone, _allowed), do: zone

  # The per-copy properties are the exception: travel time and its
  # kind are exactly the data that lives on this copy alone, and the
  # organiser never sees them.
  defp shareable(component, allowed), do: unextended(component, @per_copy ++ allowed)

  # The record that an earlier reply reached the organiser survives the
  # attendee's own edits. Their client PUTs the event back without a
  # `SCHEDULE-STATUS` — it never had one to send — and taking the
  # client's word would make every later edit look like an event they
  # had never answered.
  defp carry_reply(
         resource,
         calendar,
         organizer,
         addresses,
         %{previous: previous} = change,
         options
       )
       when is_binary(previous) do
    with {:ok, before} <- ICalendar.parse(previous),
         true <- stamped?(schedulable(before), organizer),
         false <- stamped?(schedulable(calendar), organizer) do
      record_reply(resource, calendar, organizer, addresses, change, options)
    else
      _nothing_to_carry -> :ok
    end
  end

  defp carry_reply(_resource, _calendar, _organizer, _addresses, _change, _options), do: :ok

  # Everyone else's answer is not the writer's to state. An attendee
  # saving a stale copy carries the guest list as their client last
  # saw it — other people's replies that arrived since must not be
  # unwound by it, so every line but their own is restored from the
  # stored copy.
  # A merging write replaces nothing it omits. The client asked for
  # reconciliation (`If-Schedule-Tag-Match`), so an override missing
  # from its stale copy is restored from the store — with the writer's
  # own series-level answer applied to their line, since their reply
  # covers the instances their copy never showed them. An ordinary
  # write is different: there, leaving an instance out is the
  # attendee's way of declining it, and it stays out.
  defp dropped_by_merge(
         calendar,
         %{merge: true, previous: previous} = _change,
         addresses,
         options
       )
       when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        kept = MapSet.new(calendar.components, &value(&1, "RECURRENCE-ID"))

        master =
          Enum.find(
            calendar.components,
            &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID")))
          )

        restored =
          for component <- schedulable(before),
              rid = value(component, "RECURRENCE-ID"),
              is_binary(rid),
              rid not in kept,
              do: own_answer_applied(component, master, addresses, options)

        restored

      _unreadable ->
        []
    end
  end

  defp dropped_by_merge(_calendar, _change, _addresses, _options), do: []

  defp own_answer_applied(component, nil, _addresses, _options), do: component

  defp own_answer_applied(component, master, addresses, options) do
    owned = Enum.map(addresses, &canonical_address(&1, options))

    answers =
      for property <- master.properties,
          property.name == "ATTENDEE",
          address = canonical_address(property.value, options),
          address in owned,
          into: %{},
          do: {address, Map.get(property.parameters, "PARTSTAT")}

    properties =
      Enum.map(component.properties, fn property ->
        with "ATTENDEE" <- property.name,
             address = canonical_address(property.value, options),
             answer when is_binary(answer) <- Map.get(answers, address) do
          %{
            property
            | parameters: property.parameters |> Map.put("PARTSTAT", answer) |> awaiting()
          }
        else
          _not_theirs -> property
        end
      end)

    %{component | properties: properties}
  end

  defp others_restored(component, %{previous: previous}, addresses, options)
       when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        known = answers_for(component, schedulable(before), options)

        properties =
          Enum.map(component.properties, fn property ->
            restored_line(property, known, addresses, options)
          end)

        %{component | properties: properties}

      _unreadable ->
        component
    end
  end

  defp others_restored(component, _change, _addresses, _options), do: component

  defp restored_line(%{name: "ATTENDEE", value: value} = property, known, addresses, options) do
    address = canonical_address(value, options)

    with false <- address in addresses,
         {:ok, {answer, delivery}} <- Map.fetch(known, address) do
      parameters =
        property.parameters
        |> Map.put("PARTSTAT", answer)
        |> stamped_as(delivery)
        |> awaiting()

      %{property | parameters: parameters}
    else
      _their_own_or_unknown -> property
    end
  end

  defp restored_line(property, _known, _addresses, _options), do: property

  defp stamped?(components, organizer) do
    Enum.any?(components, fn component ->
      Enum.any?(component.properties, fn property ->
        property.name == "ORGANIZER" and property.value == organizer and
          Map.has_key?(property.parameters, "SCHEDULE-STATUS")
      end)
    end)
  end

  # The `ORGANIZER` line is not the attendee's to decorate. Whatever
  # parameters their client hung on it are dropped in favour of the
  # stored spelling — except `SCHEDULE-AGENT`, which is the one thing
  # an attendee may state there (RFC 6638 section 7.1).
  defp organizer_as_held(%{name: "VTIMEZONE"} = zone, _change), do: zone

  defp organizer_as_held(component, %{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)

        counterpart =
          Enum.find(held, &(utc_rid(&1) == utc_rid(component))) ||
            Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID")))

        stated =
          case counterpart do
            nil -> nil
            found -> Enum.find(found.properties, &(&1.name == "ORGANIZER"))
          end

        %{
          component
          | properties: Enum.map(component.properties, &held_organizer_line(&1, stated))
        }

      _unreadable ->
        component
    end
  end

  defp organizer_as_held(component, _change), do: component

  defp held_organizer_line(%{name: "ORGANIZER"} = property, %{value: value, parameters: held})
       when value == property.value do
    agent = Map.take(property.parameters, ["SCHEDULE-AGENT"])
    %{property | parameters: Map.merge(held, agent)}
  end

  defp held_organizer_line(property, _stated), do: property

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
  # Only the recipients a message actually reached are marked
  # delivered. A save that told nobody stamps nobody; a forced
  # re-invitation stamps only the re-invited.
  defp stamped_for(asked, dropped, reinvited, recipients) do
    cond do
      # The dropped were messaged too — their cancellation is this
      # round's delivery, and a line still on the event (an attendee
      # moved to `SCHEDULE-AGENT=NONE`) records it like any other.
      asked != [] or dropped != [] -> Enum.uniq(recipients ++ dropped)
      reinvited != [] -> reinvited
      true -> []
    end
  end

  # Written even when nobody is stamped: the store keeps the server's
  # canonical spelling of the event either way. Only the attendees a
  # message actually went to are marked delivered — a save that told
  # nobody must not overwrite the record of an earlier reply with
  # `SCHEDULE-STATUS=1.2`.
  defp record(
         resource,
         calendar,
         recipients,
         refused,
         %{store: store, context: context} = options
       ) do
    # "2.0" is the record of an answer. A round whose auto-processing
    # answered nothing — the event is wholly past, the room's mode
    # held its peace, or nothing new was asked — leaves the plain
    # delivery mark of the messages that did go out.
    replied = Map.get(options, :auto_replied, [])
    answered = Enum.filter(recipients, &(canonical_address(&1, options) in replied))

    if Store.supports?(store, :put) do
      updated = %{
        calendar
        | components:
            calendar.components
            |> Enum.map(&stamp(&1, recipients, options))
            |> Enum.map(&auto_answered(&1, answered, options))
            |> Enum.map(&unsplit/1)
            |> Enum.map(&undeliverable(&1, refused, options))
      }

      store.put(resource.path, ICalendar.write(updated), @calendar_type, context)
    end

    :ok
  end

  # A room answers the moment it is asked: any message delivered to
  # an auto-managed recipient is processed by the server on its
  # behalf, and the organiser's copy records the reply ("2.0"), not
  # merely the delivery — an `EXDATE`-only round included, because
  # the room's server consumed that cancellation too.
  defp auto_answered(component, [], _options), do: component
  defp auto_answered(%{name: "VTIMEZONE"} = zone, _asked, _options), do: zone

  defp auto_answered(component, asked, _options) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE" and property.value in asked and
             unattended?(property.parameters) do
          parameters =
            property.parameters
            |> Map.put("SCHEDULE-STATUS", "2.0")
            |> Map.put_new("PARTSTAT", "NEEDS-ACTION")

          %{property | parameters: parameters}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  # An override the server split out of the master is bookkeeping,
  # not a question: the room's line keeps its `NEEDS-ACTION` without
  # `RSVP`, and the mark itself goes no further than this store.
  defp unsplit(component) do
    if Enum.any?(component.properties, &(&1.name == "X-DAV-SPLIT")) do
      properties =
        component.properties
        |> Enum.reject(&(&1.name == "X-DAV-SPLIT"))
        |> Enum.map(&unasked/1)

      %{component | properties: properties}
    else
      component
    end
  end

  defp unasked(property) do
    if property.name == "ATTENDEE" and unattended?(property.parameters) and
         Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION" do
      %{property | parameters: Map.delete(property.parameters, "RSVP")}
    else
      property
    end
  end

  # "5.3" is iTIP's "no scheduling support for user" — here, a
  # delivery the recipient's own copy refused: the `UID` is already a
  # different organiser's meeting on their calendar, and this message
  # claimed it.
  defp undeliverable(component, [], _options), do: component
  defp undeliverable(%{name: "VTIMEZONE"} = zone, _refused, _options), do: zone

  defp undeliverable(component, refused, options) do
    turned = Enum.map(refused, &canonical_address(&1, options))

    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE" and canonical_address(property.value, options) in turned do
          %{property | parameters: Map.put(property.parameters, "SCHEDULE-STATUS", "5.3")}
        else
          property
        end
      end)

    %{component | properties: properties}
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
  defp remembered(component, %{previous: nil}, options),
    do: restore_participation(component, [], false, options)

  defp remembered(component, %{previous: previous} = change, options) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)

        # An answer is the attendee's own and the stored one stands —
        # an organiser's client does not know what anyone said and
        # must not overwrite it in passing. A *significant* change is
        # different: when the timing moves, everyone is being asked
        # again, and their last answer was to a different meeting. A
        # rescheduled *series* re-asks every component at once — the
        # reference transfers no answer anywhere when the master moved
        # (`transferItems`, the `reschedule` flag).
        reasked =
          asked_again?(component, held) or
            reasked?(Map.get(options, :series_master), held)

        answers = if reasked, do: [], else: held

        component
        |> restore_participation(answers, Map.get(change, :merge, false), options)
        |> reset_marked(
          stated(held, value(component, "RECURRENCE-ID"), options),
          reasked,
          options
        )

      _unreadable ->
        component
    end
  end

  defp asked_again?(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    case Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence)) do
      nil ->
        moved_from_derived?(component, recurrence, held)

      before ->
        shape([component], @rescheduled) != shape([before], @rescheduled) or
          rescheduled_rule?(component, before)
    end
  end

  # A new override is measured against the occurrence it replaces —
  # the one the recipient's own rule would have produced. An override
  # that only decorates the instance (a summary, a location) changes
  # nothing the recipient agreed to; one that moves it is a fresh
  # question. The reference compares against the derived instance the
  # same way (`attendeeNeedsAction`, `icaldiff.py`).
  defp moved_from_derived?(component, recurrence, held) when is_binary(recurrence) do
    case Enum.find(held, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID")))) do
      nil ->
        false

      master ->
        derived = derived_instance(master, rid_parameters(component), recurrence)
        shape([component], @rescheduled) != shape([derived], @rescheduled)
    end
  end

  defp moved_from_derived?(_component, _recurrence, _held), do: false

  # An `RRULE` change re-asks everyone — unless it only truncates or
  # extends the series. The reference (`attendeeNeedsAction` in
  # `icaldiff.py`) strips `COUNT` and `UNTIL` before comparing: a
  # meeting that now ends two weeks earlier is the same meeting, and
  # the occurrences that remain are ones the attendees already
  # answered. Adding or removing the rule outright is a reschedule.
  defp rescheduled_rule?(component, before) do
    unbounded_rule(component) != unbounded_rule(before)
  end

  defp unbounded_rule(component) do
    case value(component, "RRULE") do
      nil ->
        nil

      rule ->
        rule
        |> String.split(";")
        |> Enum.reject(&(String.starts_with?(&1, "COUNT=") or String.starts_with?(&1, "UNTIL=")))
        |> Enum.sort()
    end
  end

  defp restore_participation(component, existing, merging, options) do
    known = answers_for(component, existing, options)
    organizer = canonical_address(value(component, "ORGANIZER"), options)

    %{
      component
      | properties:
          component.properties
          |> Enum.map(&participating(&1, known, organizer, merging, options))
    }
  end

  # RFC 6638 leaves no way to say "I am asking you again" in the
  # message itself, so the reference marks the asking: every attendee
  # of a re-timed instance, and any attendee the organiser explicitly
  # set back to `NEEDS-ACTION`, carries
  # `X-CALENDARSERVER-RESET-PARTSTAT` on the way out. The recipient's
  # server reads it as "do not restore the stored answer" — without
  # it, an attendee's copy would put their old acceptance back over a
  # question being deliberately re-put.
  defp reset_marked(component, stored, reasked, options) do
    sequence = value(component, "SEQUENCE") || "0"
    organizer = canonical_address(value(component, "ORGANIZER"), options)

    properties =
      Enum.map(component.properties, fn property ->
        address = if property.name == "ATTENDEE", do: canonical_address(property.value, options)

        deliberate? =
          Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION" and
            match?({answer, _delivery} when answer != "NEEDS-ACTION", Map.get(stored, address))

        if property.name == "ATTENDEE" and address != organizer and (reasked or deliberate?) do
          %{
            property
            | parameters:
                Map.put(property.parameters, "X-CALENDARSERVER-RESET-PARTSTAT", sequence)
          }
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  defp answers_for(component, existing, options) do
    case stated(existing, value(component, "RECURRENCE-ID"), options) do
      answered when map_size(answered) > 0 -> answered
      _none_of_its_own -> if in_place?(component), do: stated(existing, nil, options), else: %{}
    end
  end

  defp in_place?(component) do
    case {value(component, "RECURRENCE-ID"), value(component, "DTSTART")} do
      {recurrence, start} when is_binary(recurrence) and is_binary(start) -> recurrence == start
      _no_override -> true
    end
  end

  # Keyed by the person, not the spelling: the client writes `mailto:`
  # where the stored copy holds the canonical form, and a raw-text key
  # loses every stored answer on every organiser save.
  defp stated(existing, recurrence, options) do
    for old <- existing,
        value(old, "RECURRENCE-ID") == recurrence,
        property <- old.properties,
        property.name == "ATTENDEE",
        status = Map.get(property.parameters, "PARTSTAT"),
        not is_nil(status),
        into: %{},
        do:
          {canonical_address(property.value, options),
           {status, Map.get(property.parameters, "SCHEDULE-STATUS")}}
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
  defp participating(
         %{name: "ATTENDEE", value: value} = property,
         known,
         organizer,
         merging,
         options
       ) do
    address = canonical_address(value, options)

    cond do
      address == organizer ->
        property

      # `NEEDS-ACTION` is the one answer an organiser may give for
      # somebody else: it is not a claim about what they decided, it
      # is the question being put again — the reference coerces every
      # *other* value back to the stored one and leaves this alone
      # (`compareAttendeePartstats`). A *merging* write is different:
      # the client asked the server to reconcile a copy it knows is
      # stale, so even its `NEEDS-ACTION` is its ignorance of a reply
      # that already arrived, and the stored answer stands.
      not merging and Map.get(property.parameters, "PARTSTAT") == "NEEDS-ACTION" ->
        # Kept exactly as the client spelled it, `SCHEDULE-STATUS` and
        # `RSVP` included: an echo of what the server showed them
        # round-trips, and this save's own delivery restamps whoever
        # it actually reaches.
        property

      true ->
        %{property | parameters: answered_or_asked(property.parameters, known, address, merging)}
    end
  end

  defp participating(property, _known, _organizer, _merging, _options), do: property

  # The reference's `checkAttendeeAutoReply`: every occurrence inside
  # a year-long window is judged — an occurrence already over keeps
  # its `NEEDS-ACTION`, a free one is accepted, a booked one declined.
  # All alike, the whole object answers at once; mixed, the master
  # takes the majority answer and each occurrence that differs stands
  # in an override, derived where the rule alone produced it.
  defp auto_answers(components, options) do
    rooms =
      for component <- components,
          component.name != "VTIMEZONE",
          property <- component.properties,
          property.name == "ATTENDEE",
          unattended?(property.parameters) or auto_managed?(property.value, options),
          uniq: true,
          do: property.value

    Enum.reduce(rooms, {components, %{}}, fn address, {held, replied} ->
      case answered_for(held, address, options) do
        {updated, false, _master?} ->
          {updated, replied}

        {updated, true, master?} ->
          {updated, Map.put(replied, address, %{master_changed: master?})}
      end
    end)
  end

  defp answered_for(components, address, options) do
    events = Enum.filter(components, &(&1.name != "VTIMEZONE"))
    master = Enum.find(events, &is_nil(value(&1, "RECURRENCE-ID")))
    overrides = Enum.filter(events, &(not is_nil(value(&1, "RECURRENCE-ID"))))

    with {_from, _to} = window <- conflict_window(master || List.first(events)),
         busy when is_list(busy) <- room_busy(address, events, window, options),
         rows when rows != [] <-
           judged(master, overrides, address, window, busy, auto_schedule_mode(address, options)),
         true <- Enum.any?(rows, & &1.active) do
      before = master && line_partstat(master, address)
      updated = apply_answers(components, master, rows, address)

      after_master =
        Enum.find_value(updated, fn component ->
          (component.name != "VTIMEZONE" and is_nil(value(component, "RECURRENCE-ID"))) &&
            line_partstat(component, address)
        end)

      {updated, Enum.any?(rows, &Map.get(&1, :answered, false)),
       master != nil and before != after_master}
    else
      _nothing_to_answer -> {components, false, false}
    end
  end

  defp room_busy(address, events, window, options) do
    with %Resource{} = home <- home_of(address, options),
         scoped = as(home, options),
         %Resource{} = calendar <- collection(home, &event_calendar?(&1, scoped), scoped) do
      uid = Enum.find_value(events, &value(&1, "UID"))

      calendar
      |> held_calendars(uid, scoped)
      |> Enum.flat_map(&FreeBusy.periods_of(&1, window))
    else
      _nowhere_to_check -> nil
    end
  end

  # One row per occurrence: where it came from, whether it is still
  # to come, and the answer it ends up with.
  defp judged(master, overrides, address, window, busy, mode) do
    ruled = ruled_rows(master, overrides, address, window)

    stated =
      for override <- overrides,
          names_line?(override, address),
          {at, ended} <- TimeRange.occurring(override, window),
          do: row({:override, override}, override, address, at, ended)

    Enum.map(ruled ++ stated, &answer_row(&1, busy, mode))
  end

  defp ruled_rows(nil, _overrides, _address, _window), do: []

  defp ruled_rows(%{} = master, overrides, address, window) do
    if names_line?(master, address) do
      for {at, ended} <- TimeRange.occurring(master, window, nil, overrides),
          do: row(:master, master, address, at, ended)
    else
      []
    end
  end

  defp row(source, component, address, at, ended) do
    %{
      source: source,
      at: at,
      active: ahead?(ended),
      span: {at, ended},
      partstat: line_partstat(component, address)
    }
  end

  defp names_line?(component, address) do
    Enum.any?(
      component.properties,
      &(&1.name == "ATTENDEE" and &1.value == address)
    )
  end

  defp line_partstat(component, address) do
    Enum.find_value(component.properties, "NEEDS-ACTION", fn property ->
      if property.name == "ATTENDEE" and property.value == address,
        do: Map.get(property.parameters, "PARTSTAT", "NEEDS-ACTION")
    end)
  end

  defp answer_row(%{partstat: "NEEDS-ACTION", active: true} = row, busy, mode) do
    free? = not FreeBusy.overlapping?([{"BUSY", row.span}], busy)

    answer =
      case {mode, free?} do
        {:accept_always, _either} -> "ACCEPTED"
        {:decline_always, _either} -> "DECLINED"
        {:accept_if_free, true} -> "ACCEPTED"
        {:accept_if_free, false} -> "NEEDS-ACTION"
        {:decline_if_busy, false} -> "DECLINED"
        {:decline_if_busy, true} -> "NEEDS-ACTION"
        {_automatic, true} -> "ACCEPTED"
        {_automatic, false} -> "DECLINED"
      end

    %{row | partstat: answer} |> Map.put(:answered, answer != "NEEDS-ACTION")
  end

  defp answer_row(row, _busy, _mode), do: row

  # The deployment states each auto-managed user's answering mode —
  # the reference's `AutoScheduleMode` — and `automatic` is the
  # default: accept when free, decline when busy.
  defp auto_schedule_mode(address, %{store: store, context: context} = options) do
    if Store.supports?(store, :auto_schedule_mode),
      do: store.auto_schedule_mode(canonical_address(address, options), context),
      else: :automatic
  end

  defp apply_answers(components, master, rows, address) do
    counts = Enum.frequencies(Enum.map(rows, & &1.partstat))

    if map_size(counts) == 1 do
      # The one answer everything already agrees on. `NEEDS-ACTION`
      # everywhere is no answer at all — the copy stays exactly as the
      # client spelled it, and no reply is made.
      case Map.to_list(counts) do
        [{"NEEDS-ACTION", _count}] -> components
        [{answer, _count}] -> Enum.map(components, &set_answer(&1, address, answer, false))
      end
    else
      mixed_answers(components, master, rows, address, counts)
    end
  end

  # The reference breaks a tie the way Python's `max` over sorted
  # pairs does: the alphabetically first of the most common.
  defp mixed_answers(components, master, rows, address, counts) do
    {chosen, _count} =
      counts |> Enum.sort_by(fn {answer, count} -> {-count, answer} end) |> List.first()

    asked_before? = master != nil and had_rsvp?(master, address)

    derived =
      for %{source: :master, partstat: answer, at: at} <- rows,
          answer != chosen,
          spelled = spelled_instant(at),
          is_binary(spelled),
          do: master |> override_at(spelled) |> set_answer(address, answer, asked_before?)

    Enum.map(components, &answered_component(&1, rows, address, chosen)) ++ derived
  end

  defp answered_component(component, rows, address, chosen) do
    cond do
      component.name == "VTIMEZONE" ->
        component

      is_nil(value(component, "RECURRENCE-ID")) ->
        set_answer(component, address, chosen, false)

      true ->
        case Enum.find(rows, &(&1.source == {:override, component})) do
          %{partstat: answer} -> set_answer(component, address, answer, false)
          nil -> component
        end
    end
  end

  defp spelled_instant(at) do
    case Tempo.to_elixir(at) do
      {:ok, %DateTime{} = moment} -> Calendar.strftime(moment, "%Y%m%dT%H%M%SZ")
      {:ok, %NaiveDateTime{} = moment} -> Calendar.strftime(moment, "%Y%m%dT%H%M%S")
      {:ok, %Date{} = moment} -> Calendar.strftime(moment, "%Y%m%d")
      _unspellable -> nil
    end
  end

  defp had_rsvp?(component, address) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and property.value == address and
        Map.get(property.parameters, "RSVP") == "TRUE"
    end)
  end

  defp set_answer(%{name: "VTIMEZONE"} = zone, _address, _answer, _had_rsvp), do: zone

  defp set_answer(component, address, answer, had_rsvp) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE" and property.value == address,
          do: %{property | parameters: answer_parameters(property.parameters, answer, had_rsvp)},
          else: property
      end)

    %{component | properties: properties}
  end

  # Still being asked: `RSVP` travels, and an implied `NEEDS-ACTION`
  # keeps the client's spelling — the absent parameter *is* the value.
  defp answer_parameters(parameters, "NEEDS-ACTION", true) do
    if Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION",
      do: Map.put(parameters, "RSVP", "TRUE"),
      else: parameters |> Map.put("PARTSTAT", "NEEDS-ACTION") |> Map.put("RSVP", "TRUE")
  end

  # No longer being asked — an occurrence already over: the question
  # is withdrawn with the answer left open.
  defp answer_parameters(parameters, "NEEDS-ACTION", false) do
    if Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION",
      do: Map.delete(parameters, "RSVP"),
      else: parameters |> Map.put("PARTSTAT", "NEEDS-ACTION") |> Map.delete("RSVP")
  end

  # Re-affirming what the line already says changes nothing — a
  # client's `RSVP=TRUE` echo beside its restated answer survives the
  # judging. Only an answer that *moves* the line consumes the asking.
  defp answer_parameters(parameters, answer, _had_rsvp) do
    if Map.get(parameters, "PARTSTAT") == answer,
      do: parameters,
      else: parameters |> Map.put("PARTSTAT", answer) |> Map.delete("RSVP")
  end

  # A derived override says what the rule alone said, at one moment —
  # everything but the rule itself, named by its occurrence.
  defp override_at(master, spelled) do
    stated =
      case Enum.find(master.properties, &(&1.name == "DTSTART")) do
        nil -> %{}
        property -> Map.delete(property.parameters, "TZID")
      end

    %{
      master
      | properties: [
          %{name: "DTSTART", parameters: stated, value: spelled},
          %{name: "RECURRENCE-ID", parameters: stated, value: spelled},
          # A transient mark: this override is the server's
          # bookkeeping, not a fresh question, so the organiser's copy
          # must not re-ask (`RSVP`) the room it split out. Stripped
          # before storing, never delivered.
          %{name: "X-DAV-SPLIT", parameters: %{}, value: "TRUE"}
          | Enum.reject(master.properties, &(&1.name in ~w(RRULE RDATE EXDATE DTSTART)))
        ]
    }
  end

  # Nobody needs a room in the past. An occurrence already over is
  # not answered — the reference's auto-processing accepts and
  # declines only what is still to come, and an event that is wholly
  # over is delivered without being processed at all.
  defp future_occurrence?(component) do
    case conflict_window(component) do
      {_from, _to} = window ->
        window
        |> then(&TimeRange.occurring(component, &1))
        |> Enum.any?(fn {_at, ended} -> ahead?(ended) end)

      _unreadable ->
        true
    end
  end

  defp ahead?(moment) do
    case Tempo.to_elixir(moment) do
      {:ok, %DateTime{} = at} -> DateTime.after?(at, DateTime.utc_now())
      {:ok, %NaiveDateTime{} = at} -> NaiveDateTime.after?(at, NaiveDateTime.utc_now())
      {:ok, %Date{} = at} -> Date.after?(at, Date.utc_today())
      _unspellable -> true
    end
  end

  defp held_calendars(calendar, uid, %{store: store, context: context} = options) do
    case store.children(calendar, context) do
      {:ok, children} ->
        for object <- children,
            not object.collection?,
            {:ok, body} <- [read(object, options)],
            {:ok, held} <- [ICalendar.parse(IO.iodata_to_binary(body))],
            Enum.find_value(held.components, &value(&1, "UID")) != uid,
            do: held

      _nothing ->
        []
    end
  end

  defp conflict_window(component) do
    case value(component, "DTSTART") do
      <<year::binary-size(4), rest::binary-size(4), _tail::binary>> ->
        {year <> rest <> "T000000Z",
         Integer.to_string(String.to_integer(year) + 1) <> rest <> "T000000Z"}

      _absent_or_short ->
        nil
    end
  end

  defp record_for(_known, _address, false), do: nil

  defp record_for(known, address, true) do
    case Map.get(known, address) do
      {_answer, delivery} -> delivery
      _no_record -> nil
    end
  end

  # Being put back to `NEEDS-ACTION` is being asked, and asking
  # carries `RSVP=TRUE` — the attendee's client uses it to know a
  # reply is wanted rather than that the event simply appeared.
  defp answered_or_asked(parameters, known, value, merging) do
    # `SCHEDULE-STATUS` is the server's record of its own deliveries.
    # A client echoing one back is repeating what it read, and a
    # fresh attendee carrying one is claiming a delivery that never
    # happened — the stored value stands, or none does.
    case Map.fetch(known, value) do
      # A client repeating the stored answer is echoing what the
      # server showed it, and the echo round-trips as written —
      # `RSVP` and `SCHEDULE-STATUS` included. Only a *different*
      # answer is the organiser speaking for somebody, and is
      # coerced back to the record. A merging write is stale, not an
      # echo: the client asked for reconciliation, and the stored
      # record is restored over whatever its old copy carried.
      {:ok, {answer, _delivery}} ->
        restated_answer(parameters, answer, known, value, merging)

      :error ->
        # No stored answer and nothing worth writing: an absent
        # `PARTSTAT` *is* `NEEDS-ACTION`, and the reference leaves
        # it as the client spelled it rather than writing the
        # default out. A stated value other than the default was
        # the organiser answering for somebody and is reset.
        parameters
        |> reset_unanswered()
        |> Map.delete("SCHEDULE-STATUS")
        |> awaiting()
    end
  end

  defp restated_answer(parameters, answer, known, value, merging) do
    if not merging and Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") == answer do
      parameters
    else
      parameters
      |> Map.put("PARTSTAT", answer)
      |> stamped_as(record_for(known, value, merging))
      |> awaiting()
    end
  end

  # Still to answer is still being asked. `RSVP=TRUE` is not a
  # separate fact from `PARTSTAT=NEEDS-ACTION` — it is what tells the
  # attendee's client that a reply is wanted — so the two travel
  # together, and once somebody has answered the asking stops.
  defp awaiting(parameters) do
    if Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION",
      do: Map.put(parameters, "RSVP", "TRUE"),
      else: Map.delete(parameters, "RSVP")
  end

  defp reset_unanswered(parameters) do
    case Map.get(parameters, "PARTSTAT") do
      nil -> parameters
      "NEEDS-ACTION" -> parameters
      _claimed -> Map.put(parameters, "PARTSTAT", "NEEDS-ACTION")
    end
  end

  defp stamped_as(parameters, nil), do: Map.delete(parameters, "SCHEDULE-STATUS")
  defp stamped_as(parameters, delivery), do: Map.put(parameters, "SCHEDULE-STATUS", delivery)

  defp unattended?(parameters), do: Map.get(parameters, "CUTYPE") in ~w(RESOURCE ROOM)

  defp stamp(component, recipients, options) do
    properties =
      component.properties
      |> Enum.map(&cleared_status(&1, recipients))
      |> Enum.map(&delivered(&1, recipients))
      |> Enum.map(&canonical(&1, options))

    %{component | properties: properties}
  end

  # A delivering save re-states the delivery record: `SCHEDULE-STATUS`
  # says what became of *this* round of messages, so an attendee who
  # was not sent one this time — their agent is `NONE`, or they were
  # dropped from the round — carries none. A save that delivers
  # nothing preserves the record of the last one that did.
  defp cleared_status(property, []), do: property

  defp cleared_status(%{name: "ATTENDEE"} = property, _recipients),
    do: %{property | parameters: Map.delete(property.parameters, "SCHEDULE-STATUS")}

  defp cleared_status(property, _recipients), do: property

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
    parameters =
      case common_name(address, options) do
        nil -> parameters
        name -> Map.put(parameters, "CN", name)
      end

    # Like the `CN`, what kind of calendar user this is comes from the
    # directory, not the client: an auto-managed address is a
    # resource whether or not the invitation said so.
    if auto_managed?(address, options),
      do: Map.put_new(parameters, "CUTYPE", "RESOURCE"),
      else: parameters
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

  defp canonical_address(nil, _options), do: nil

  defp canonical_address(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :canonical_address, 2),
         {:ok, canonical} <- store.canonical_address(address, context) do
      canonical
    else
      _not_hosted_here -> address
    end
  end

  # "1.2" is iTIP's "scheduling message has been delivered". Being
  # delivered to while still unanswered is being *asked*, and asking
  # carries `RSVP=TRUE` — a quiet save that delivers nothing adds no
  # asking of its own.
  defp delivered(%{name: "ATTENDEE", value: value} = property, recipients) do
    if value in recipients do
      %{
        property
        | parameters:
            property.parameters |> Map.put("SCHEDULE-STATUS", "1.2") |> asked_if_unanswered()
      }
    else
      property
    end
  end

  defp delivered(property, _recipients), do: property

  # The delivery adds the asking where an answer is still wanted, but
  # takes nothing away: a client that spelled `RSVP=TRUE` beside an
  # answer it was restating keeps its echo.
  defp asked_if_unanswered(parameters) do
    if Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION",
      do: Map.put(parameters, "RSVP", "TRUE"),
      else: parameters
  end

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

  defp send_to([], _method, _components, _zones, _options, _announced), do: []
  defp send_to(_recipients, _method, [], _zones, _options, _announced), do: []

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

    for recipient <- recipients,
        home = home_of(recipient, options),
        not is_nil(home),
        seen = viewed(method, told, recipient, options),
        seen != [],
        :refused ==
          deliver_to(
            home,
            recipient,
            method,
            viewed(method, normalised, recipient, options),
            seen,
            zones,
            options
          ),
        do: recipient
  end

  # Each recipient sees the instances that name them. An update whose
  # only news is an override the recipient was left out of is no news
  # to them at all — the reference's `attendeesView` drops components
  # missing the attendee, and an empty message is not sent; the
  # instance they lost reaches them as a `CANCEL` instead. The copy
  # kept in their calendar is built from the same view, so a dropped
  # override becomes an `EXDATE` on their master: without it, their
  # own rule would conjure the very instance the organiser is holding
  # without them.
  defp viewed("REQUEST", components, recipient, options) do
    address = canonical_address(recipient, options)
    {kept, removed} = Enum.split_with(components, &names?(&1, address, options))

    kept
    |> excluding_unseen(removed)
    |> Enum.map(&asking/1)
  end

  defp viewed(_method, components, _recipient, _options), do: components

  # A `REQUEST` is the asking itself: every attendee still to answer
  # carries `RSVP=TRUE` in the message, and an answered one carries no
  # request for a reply.
  defp asking(%{name: "VTIMEZONE"} = zone), do: zone

  defp asking(component) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ATTENDEE",
          do: %{property | parameters: awaiting(property.parameters)},
          else: property
      end)

    %{component | properties: properties}
  end

  # Spelled in UTC, the way the reference writes a derived exclusion
  # (`getRecurrenceIDUTC` and `adjustToUTC`): the recipient's copy
  # compares and round-trips the instant, not the sender's zone.
  defp exclusion_property(rid, parameters) do
    case utc_form(rid, parameters) do
      ^rid -> %{name: "EXDATE", parameters: parameters, value: rid}
      utc -> %{name: "EXDATE", parameters: %{}, value: utc}
    end
  end

  # The same occurrence may be named in its own zone by one copy and
  # in UTC by another — the reference compares recurrence identifiers
  # as UTC instants (`getRecurrenceIDUTC`) for exactly this reason. A
  # floating or already-UTC value is returned as written.
  defp utc_form(rid, parameters) do
    with zone when is_binary(zone) <- Map.get(parameters, "TZID"),
         [_full, y, mo, d, h, mi, sec] <-
           Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/, rid),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             String.to_integer(mo),
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(sec)
           ),
         {:ok, local} <- DateTime.from_naive(naive, zone),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC") do
      Calendar.strftime(utc, "%Y%m%dT%H%M%SZ")
    else
      _floating_or_utc_already -> rid
    end
  end

  # A component's recurrence identifier as a UTC instant, or `nil`
  # for a master.
  defp utc_rid(component) do
    case Enum.find(component.properties, &(&1.name == "RECURRENCE-ID")) do
      nil -> nil
      property -> utc_form(property.value, property.parameters)
    end
  end

  defp utc_exclusion_set(master) do
    for property <- master.properties,
        property.name == "EXDATE",
        instance <- String.split(property.value, ","),
        into: MapSet.new(),
        do: utc_form(instance, property.parameters)
  end

  defp excluding_unseen(kept, []), do: kept

  defp excluding_unseen(kept, removed) do
    exclusions =
      for component <- removed,
          rid = value(component, "RECURRENCE-ID"),
          is_binary(rid),
          do: exclusion_property(rid, rid_parameters(component))

    Enum.map(kept, fn component ->
      if component.name != "VTIMEZONE" and is_nil(value(component, "RECURRENCE-ID")) do
        %{component | properties: component.properties ++ exclusions}
      else
        component
      end
    end)
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

    # A component the pipeline added — a dropped override put back —
    # is part of the record even though the client's body never held
    # it.
    written = MapSet.new(calendar.components, &{&1.name, value(&1, "RECURRENCE-ID")})

    added =
      Enum.reject(components, &({&1.name, value(&1, "RECURRENCE-ID")} in written))

    %{calendar | components: replaced ++ added}
  end

  defp notified(recipients, _components, %{previous: nil}, _options), do: recipients

  # Compared as *processed* — participation restored, sequence synced
  # — against the stored copy. The raw body says what the client
  # typed; the processed one says what actually changed, and a raised
  # `SEQUENCE` counts (the reference re-sends on it) while a lowered
  # one was already pulled back up and so compares equal.
  defp notified(recipients, components, %{previous: previous}, options) do
    if shared_components(components, options) == shared(previous, options),
      do: [],
      else: recipients
  end

  # The event as the attendees see it. Alarms are removed because they
  # are personal; the timestamps because every save moves them and no
  # attendee is waiting to hear it; and the parameters the server
  # maintains because they record what became of past messages rather
  # than anything this one carries.
  defp still_holds?(address, components, options) do
    uid = Enum.find_value(components, &value(&1, "UID"))

    with %Resource{} = home <- home_of(address, options),
         %Resource{} = calendar <- collection(home, &event_calendar?(&1, options), options),
         %Resource{} <- object_with(calendar, uid, options) do
      true
    else
      _no_copy_of_their_own -> false
    end
  end

  defp shared(body, options) do
    case ICalendar.parse(body) do
      {:ok, calendar} -> shared_components(schedulable(calendar), options)
      _unreadable -> nil
    end
  end

  @unremarkable ~w(DTSTAMP LAST-MODIFIED CREATED)

  defp shared_components([], _options), do: nil

  defp shared_components(components, options) do
    allowed = extensions(options)

    for component <-
          components |> Enum.map(&without_alarms/1) |> Enum.map(&unextended(&1, allowed)),
        property <- component.properties,
        property.name not in @unremarkable,
        into: MapSet.new(),
        do:
          {value(component, "RECURRENCE-ID"), property.name, addressed_as(property, options),
           Map.delete(comparable(property.parameters), "PARTSTAT"), delivers?(property)}
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
  # Whether the save changed anything beyond the withdrawal itself:
  # `STATUS`, the exclusion list, and the properties every save moves
  # are set aside, and what is left is compared.
  defp only_cancellation?(%{previous: nil}, _options), do: false

  defp only_cancellation?(%{body: body, previous: previous}, options) do
    substance(body, options) == substance(previous, options)
  end

  # Compared in canonical form — the client writes `mailto:` where the
  # stored copy holds `urn:x-uid:`, and the parameters the server
  # maintains are its own, so neither difference is the client saying
  # anything.
  defp substance(body, options) do
    case ICalendar.parse(body) do
      {:ok, calendar} ->
        for component <- schedulable(calendar),
            property <- component.properties,
            property.name not in ["STATUS" | @bookkeeping],
            into: MapSet.new(),
            do:
              {value(component, "RECURRENCE-ID"), property.name, addressed_as(property, options),
               comparable(property.parameters)}

      _unreadable ->
        nil
    end
  end

  defp announced(components, %{previous: nil}, _options), do: every(components)

  defp announced(components, %{previous: previous}, options) do
    case ICalendar.parse(previous) do
      {:ok, before} -> narrowed(components, altered(components, schedulable(before), options))
      _unreadable -> every(components)
    end
  end

  # An update that touches the master announces the whole set. The
  # reference's `filterComponents` leaves the message unfiltered when
  # the master is among the changed instances — the recipient's copy
  # is rebuilt from it wholesale — and narrows to just the changed
  # overrides only when the master stood still.
  defp narrowed(components, nil), do: every(components)

  defp narrowed(components, altered) do
    if nil in altered, do: every(components), else: altered
  end

  # `nil` rather than `[]` when nothing changed, so the caller falls
  # back to announcing everything: a message with no components at all
  # is not a smaller message, it is a broken one.
  defp altered(components, held, options) do
    case for component <- components,
             altered?(component, held, options),
             do: recurrence(component) do
      [] -> nil
      some -> some
    end
  end

  defp every(components), do: for(component <- components, do: recurrence(component))

  # The instances this edit brought into being. Everything else the
  # message carries, the recipients have been told about before.
  defp created(components, %{previous: nil}), do: every(components)

  defp created(components, %{previous: previous}) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        known = MapSet.new(schedulable(before), &recurrence/1)

        for component <- components, recurrence(component) not in known, do: recurrence(component)

      _unreadable ->
        every(components)
    end
  end

  defp recurrence(component), do: value(component, "RECURRENCE-ID")

  defp altered?(component, held, options) do
    case Enum.find(held, &(recurrence(&1) == recurrence(component))) do
      nil -> true
      previous -> instance(component, options) != instance(previous, options)
    end
  end

  # Compared as people and canonical parameters, not spellings: the
  # client writes `mailto:` and no `EMAIL`/`CN` where the stored copy
  # carries the canonical address with both, and raw comparison made
  # every save look like a change to every component.
  defp instance(component, options) do
    for property <- component.properties,
        property.name not in @bookkeeping,
        into: MapSet.new(),
        do: {property.name, addressed_as(property, options), comparable(property.parameters)}
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
    # The reset marker is the server's own signal to the recipient's
    # server, not a client extension — it always travels, whatever the
    # deployment shares.
    String.starts_with?(name, "X-") and name != "X-CALENDARSERVER-RESET-PARTSTAT" and
      name not in allowed
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
    options = as(home, options)

    if forged?(home, method, components, uid, options) do
      :refused
    else
      delivered_to(home, recipient, method, components, told, zones, uid, options)
    end
  end

  # RFC 6638 section 3.2.2: one meeting, one organiser. A message
  # whose `UID` the recipient already holds under a *different*
  # organiser is somebody claiming another person's meeting — it is
  # not delivered, not deposited, and the sender's copy records `5.3`
  # rather than success.
  defp forged?(home, method, components, uid, options) when method in ~w(REQUEST CANCEL) do
    with %Resource{} = calendar <- holding_calendar(home, uid, options),
         %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body),
         held when is_binary(held) <- organizer_of(schedulable(stored)),
         sent when is_binary(sent) <- organizer_of(components) do
      canonical_address(held, options) != canonical_address(sent, options)
    else
      _no_copy_or_no_organizer -> false
    end
  end

  defp forged?(_home, _method, _components, _uid, _options), do: false

  defp deposit_message(home, method, told, zones, uid, components, recipient, options) do
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
  end

  # Whether the server answered for this recipient anywhere in the
  # object: any `ACCEPTED` or `DECLINED` on their line is a reply.
  defp answered_in?(components, recipient, options) do
    address = canonical_address(recipient, options)

    Enum.any?(components, fn component ->
      component.name != "VTIMEZONE" and
        Enum.any?(component.properties, fn property ->
          property.name == "ATTENDEE" and
            canonical_address(property.value, options) == address and
            Map.get(property.parameters, "PARTSTAT") in ["ACCEPTED", "DECLINED"]
        end)
    end)
  end

  defp auto_managed?(recipient, %{store: store, context: context} = options) do
    Store.supports?(store, :unattended?) and
      store.unattended?(canonical_address(recipient, options), context)
  end

  defp delivered_to(home, recipient, method, components, told, zones, uid, options) do
    # Nobody reads a room's Inbox for what the server already
    # answered. A message the auto-processing could not answer — the
    # room was busy and its mode holds rather than declines — queues
    # for a delegate; one wholly in the past is not worth the storage.
    if consumed?(recipient, method, components, options) do
      :ok
    else
      deposit_message(home, method, told, zones, uid, components, recipient, options)
    end

    case {method, holding_calendar(home, uid, options) || provisioned(method, home, options)} do
      {"REQUEST", %Resource{} = calendar} ->
        write_request(calendar, recipient, components, told, zones, uid, options)

      {"REPLY", %Resource{} = calendar} ->
        apply_reply(calendar, components, uid, options)

      # A cancelled event is *marked* cancelled, not removed. The
      # attendee had it in their calendar and may have arranged their
      # day around it; making it vanish leaves them wondering where it
      # went, while `STATUS:CANCELLED` says what happened and lets
      # them delete it themselves.
      {"CANCEL", %Resource{} = calendar} ->
        cancel(calendar, components, uid, options, recipient)

      _no_calendar ->
        :ok
    end

    :ok
  end

  # A `REQUEST` the processing answered, a `CANCEL` (consumed on
  # arrival — the reference stores no inbox item for an auto-processed
  # cancellation), or anything wholly in the past.
  # An auto-managed copy carries the organiser's bookkeeping on its
  # master even when the round only announced an override: the
  # reference rebuilds the room's copy from the message, so its
  # `SEQUENCE` and its exclusions read exactly as the organiser
  # spelled them.
  defp master_refreshed(component, components) do
    with nil <- value(component, "RECURRENCE-ID"),
         true <- component.name != "VTIMEZONE",
         %{} = stated <-
           Enum.find(
             components,
             &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID")))
           ) do
      carried = Enum.filter(stated.properties, &(&1.name == "EXDATE"))

      %{
        component
        | properties: Enum.reject(component.properties, &(&1.name == "EXDATE")) ++ carried
      }
    else
      _not_a_master_or_no_message_master -> component
    end
  end

  defp consumed?(recipient, method, components, options) do
    is_binary(recipient) and auto_managed?(recipient, options) and
      (method == "CANCEL" or
         answered_in?(components, recipient, options) or
         not Enum.any?(components, &(&1.name != "VTIMEZONE" and future_occurrence?(&1))))
  end

  defp write_request(calendar, recipient, components, told, zones, uid, options) do
    address = canonical_address(recipient, options)
    auto? = auto_managed?(recipient, options)

    replied? = address in Map.get(options, :auto_master_answered, [])
    renumbered = Map.get(options, :client_renumbered, [])

    synced =
      if auto?,
        do: fn component -> in_sequence(component, told, components, replied?, renumbered) end,
        else: fn component -> component end

    refreshed =
      if auto?,
        do: fn kept -> Enum.map(kept, &master_refreshed(&1, components)) end,
        else: fn kept -> kept end

    delivered =
      calendar
      |> preserving(recipient, components, told, uid, options)
      |> refreshed.()
      |> Enum.map(synced)
      |> Enum.map(&auto_accepted(&1, address, auto?))
      |> Enum.map(&transparent_until_answered(&1, address))
      |> Enum.map(&unmarked/1)
      |> Enum.map(&schedulable_after_all/1)

    # A delivery that kept nothing stores nothing: an arrival that was
    # all old refusals leaves the calendar as it stands rather than
    # planting an empty shell.
    if Enum.any?(delivered, &(&1.name != "VTIMEZONE")) do
      store(calendar, own_copy(delivered, zones, address), uid, options)
    else
      :ok
    end
  end

  # The calendar that already holds the meeting, wherever the
  # recipient keeps it — a copy moved into another calendar of theirs
  # is still the copy, and delivering to the first calendar found
  # would plant a duplicate beside it. A home holding no copy at all
  # answers with its first calendar.
  defp holding_calendar(home, uid, %{store: store, context: context} = options) do
    case store.children(home, context) do
      {:ok, children} ->
        calendars = Enum.filter(children, &Cal.calendar?/1)

        Enum.find(calendars, &object_with(&1, uid, options)) ||
          Enum.find(calendars, &event_calendar?(&1, options))

      _nothing ->
        nil
    end
  end

  # Nobody sits at a room's keyboard to accept, so its own copy
  # answers on arrival: the line goes to `ACCEPTED` before the
  # transparency rule looks at it, and the room's time reads busy the
  # moment it is booked.
  # A home with no calendar still receives invitations: the reference
  # provisions the default calendar on first delivery rather than
  # bouncing the message. Only a `REQUEST` creates one — a `CANCEL` or
  # `REPLY` for a copy that cannot exist has nothing to update.
  defp provisioned("REQUEST", home, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :mkcalendar),
         {:ok, _made} <- store.mkcalendar(home.path ++ ["calendar"], context) do
      collection(home, &event_calendar?(&1, options), options)
    else
      _cannot_provision -> nil
    end
  end

  defp provisioned(_method, _home, _options), do: nil

  # A kept component's version never trails the one the organiser now
  # numbers it with — but only where a number actually travelled: a
  # component delivered this round carries its own; the master follows
  # when the room was asked and answered again; an override follows
  # when the client itself renumbered it. A server-side bump the
  # message never carried stays the organiser's own bookkeeping.
  defp in_sequence(%{name: "VTIMEZONE"} = zone, _told, _view, _replied?, _renumbered), do: zone

  defp in_sequence(component, told, view, replied?, renumbered) do
    rid = utc_rid(component)

    stated =
      followed?(rid, told, replied?, renumbered) and
        Enum.find(view, fn candidate ->
          candidate.name != "VTIMEZONE" and utc_rid(candidate) == rid
        end)

    if match?(%{}, stated) and sequence_of(stated) > sequence_of(component) do
      renumber = %{
        name: "SEQUENCE",
        parameters: %{},
        value: Integer.to_string(sequence_of(stated))
      }

      %{
        component
        | properties: Enum.reject(component.properties, &(&1.name == "SEQUENCE")) ++ [renumber]
      }
    else
      component
    end
  end

  defp followed?(rid, told, replied?, renumbered) do
    Enum.any?(told, &(&1.name != "VTIMEZONE" and utc_rid(&1) == rid)) or
      (is_nil(rid) and replied?) or
      (not is_nil(rid) and rid in renumbered)
  end

  defp sequence_of(component) do
    case Integer.parse(value(component, "SEQUENCE") || "0") do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp auto_accepted(component, _address, false), do: component
  defp auto_accepted(%{name: "VTIMEZONE"} = zone, _address, _auto), do: zone

  defp auto_accepted(component, address, true) do
    properties = Enum.map(component.properties, &arrived_answer(&1, address))

    # The reference adjusts `TRANSP` to match the answer on every
    # processed component: a declined booking does not hold the room —
    # the next free-busy check can say yes to somebody else — and an
    # accepted one holds it whatever an earlier refusal left behind.
    cond do
      declined_by?(properties, address) ->
        %{component | properties: transparent(properties)}

      accepted_by?(properties, address) ->
        %{component | properties: opaque(properties)}

      true ->
        %{component | properties: properties}
    end
  end

  defp accepted_by?(properties, address) do
    Enum.any?(properties, fn property ->
      property.name == "ATTENDEE" and property.value == address and
        Map.get(property.parameters, "PARTSTAT") == "ACCEPTED"
    end)
  end

  defp opaque(properties) do
    Enum.reject(properties, &(&1.name == "TRANSP")) ++
      [%{name: "TRANSP", parameters: %{}, value: "OPAQUE"}]
  end

  # The organiser's server already asked this room's calendar, and
  # the line arrives carrying the answer — or carrying no answer,
  # when there was nothing to answer. Either way the delivered value
  # is the record; only the request for a reply is dropped once one
  # exists.
  defp arrived_answer(property, address) do
    if property.name == "ATTENDEE" and property.value == address and
         unattended?(property.parameters) and
         Map.get(property.parameters, "PARTSTAT") in ["ACCEPTED", "DECLINED"] do
      %{property | parameters: Map.delete(property.parameters, "RSVP")}
    else
      property
    end
  end

  defp declined_by?(properties, address) do
    Enum.any?(properties, fn property ->
      property.name == "ATTENDEE" and property.value == address and
        Map.get(property.parameters, "PARTSTAT") == "DECLINED"
    end)
  end

  # "5.3" on the recipient's own `ORGANIZER` line said this meeting
  # could not be scheduled with — and the invitation now arriving is
  # the proof it can. The reply marks ("2.0", "1.2") are a different
  # record and stand.
  # The marker did its job on the way in; the recipient's copy keeps
  # the reset, not the bookkeeping (the reference strips it the same
  # way once processing is done).
  defp unmarked(component) do
    properties =
      Enum.map(component.properties, fn property ->
        %{
          property
          | parameters: Map.delete(property.parameters, "X-CALENDARSERVER-RESET-PARTSTAT")
        }
      end)

    %{component | properties: properties}
  end

  defp schedulable_after_all(%{name: "VTIMEZONE"} = zone), do: zone

  defp schedulable_after_all(component) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "ORGANIZER" and
             Map.get(property.parameters, "SCHEDULE-STATUS") == "5.3" do
          %{property | parameters: Map.delete(property.parameters, "SCHEDULE-STATUS")}
        else
          property
        end
      end)

    %{component | properties: properties}
  end

  # Written as the person it is written for. Whether an event makes
  # *you* busy, and what you want reminding of, are yours rather than
  # the event's — a store keeps them per principal, and writing them
  # while scoped to the sender files one person's answers under
  # another's name.
  defp as(%Resource{owner: owner}, %{store: store, context: context} = options)
       when is_binary(owner) do
    if Store.supports?(store, :scope),
      do: %{options | context: store.scope(context, owner)},
      else: options
  end

  defp as(_home, options), do: options

  # A REPLY is not just a message to read: the organiser's own copy of
  # the event has to show that this attendee accepted. Delivering the
  # reply to the Inbox and leaving the event unchanged means the
  # organiser's calendar shows everyone as NEEDS-ACTION for ever —
  # RFC 6638 section 4.2 makes applying it the server's job.
  defp apply_reply(calendar, replies, uid, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      allowed = extensions(options)

      # The reply speaks UTC; this copy speaks its own zone. An
      # instance identifier arriving as `...Z` is rewritten into the
      # master's `TZID` before matching, or the same moment reads as
      # two different occurrences.
      replies =
        Enum.map(
          replies,
          &localized_to(
            &1,
            Enum.find(stored.components, fn c ->
              is_nil(value(c, "RECURRENCE-ID")) and c.name != "VTIMEZONE"
            end)
          )
        )

      # A reply that answers the series answers its instances too: a
      # stored override the message says nothing about takes the
      # master's answer, the way the reference derives one from the
      # reply's master for every uncovered instance (`processReply`).
      spoken = Enum.find(replies, &is_nil(value(&1, "RECURRENCE-ID")))

      answered =
        Enum.map(stored.components, fn component ->
          accept(component, replying(component, replies, spoken), allowed)
        end)

      updated = %{stored | components: answered ++ separated(stored, replies, allowed)}

      write(object, ICalendar.write(updated), options)
      noted_etag(object, options)
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
  defp localized_to(component, nil), do: component
  defp localized_to(%{name: "VTIMEZONE"} = zone, _master), do: zone

  defp localized_to(component, master) do
    with start when is_binary(start) <- value(component, "RECURRENCE-ID"),
         true <- String.ends_with?(start, "Z"),
         %{parameters: %{"TZID" => zone}} <-
           Enum.find(master.properties, &(&1.name == "DTSTART")) do
      %{component | properties: Enum.map(component.properties, &localized_or_kept(&1, zone))}
    else
      _already_local -> component
    end
  end

  defp localized_or_kept(property, zone) do
    if property.name in ~w(RECURRENCE-ID DTSTART),
      do: localized_property(property, zone),
      else: property
  end

  defp localized_property(%{value: value} = property, zone) do
    with [_full, y, mo, d, h, mi, sec] <-
           Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/, value),
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             String.to_integer(mo),
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(sec)
           ),
         {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC"),
         {:ok, local} <- DateTime.shift_zone(utc, zone) do
      %{
        property
        | parameters: Map.put(property.parameters, "TZID", zone),
          value: Calendar.strftime(local, "%Y%m%dT%H%M%S")
      }
    else
      _unconvertible -> property
    end
  end

  defp refreshed(updated, uid, answering, options) do
    components = schedulable(updated)
    organizer = Enum.find_value(components, &value(&1, "ORGANIZER"))

    for address <- attendees_of(components),
        address != organizer,
        address not in answering,
        home = home_of(address, options),
        not is_nil(home),
        calendar = collection(home, &event_calendar?(&1, options), options),
        not is_nil(calendar) do
      restated_for(calendar, uid, address, components, options)
    end

    :ok
  end

  # The reference's `addTranspForNeedsAction`: an event the recipient
  # has not answered does not make them busy. Their free-busy shows
  # the meetings they are *in*, not every invitation sitting unread —
  # and the moment they accept, their own `TRANSP` takes over.
  defp transparent_until_answered(%{name: "VEVENT"} = component, address) do
    unanswered? =
      Enum.any?(component.properties, fn property ->
        property.name == "ATTENDEE" and property.value == address and
          Map.get(property.parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION"
      end)

    if unanswered? do
      stated = %{name: "TRANSP", parameters: %{}, value: "TRANSPARENT"}

      %{
        component
        | properties: Enum.reject(component.properties, &(&1.name == "TRANSP")) ++ [stated]
      }
    else
      component
    end
  end

  defp transparent_until_answered(component, _address), do: component

  defp answering(replies) do
    for component <- replies,
        property <- component.properties,
        property.name == "ATTENDEE",
        uniq: true,
        do: property.value
  end

  defp restated_for(calendar, uid, address, components, options) do
    allowed = extensions(options)

    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      revised =
        Enum.map(stored.components, &restated_component(&1, components, address, allowed))

      # An override the organiser's copy gained — an attendee turning
      # one instance down carves it out of the series — reaches this
      # copy too. Rewriting only the components it already holds
      # leaves every other attendee seeing the old answer on that
      # date for ever.
      held = MapSet.new(stored.components, &value(&1, "RECURRENCE-ID"))
      gone = stored.components |> Enum.find(&is_nil(value(&1, "RECURRENCE-ID"))) |> exclusions()

      # Not every override travels. One the recipient is not part of
      # is not theirs to hold; one they excluded themselves, or turned
      # down, stays refused; and a cancelled instance is the CANCEL's
      # to deliver, not the refresh's.
      added =
        for component <- components,
            component.name != "VTIMEZONE",
            rid = value(component, "RECURRENCE-ID"),
            is_binary(rid),
            rid not in held,
            rid not in gone,
            not cancelled?(component),
            names?(component, canonical_address(address, options), options),
            not declined_in?(component, address, options),
            do: component |> unstamped() |> without_alarms() |> unextended(allowed)

      write(object, ICalendar.write(%{stored | components: revised ++ added}), options)
      noted_etag(object, options)
    else
      _no_copy_of_their_own -> :ok
    end
  end

  defp exclusions(nil), do: MapSet.new()
  defp exclusions(master), do: exclusion_set(master)

  defp restated_component(component, components, address, allowed) do
    case Enum.find(components, &(value(&1, "RECURRENCE-ID") == value(component, "RECURRENCE-ID"))) do
      nil -> component
      known -> component |> retold(known, address, allowed) |> carried([known], allowed)
    end
  end

  # Their own line is theirs; every other participant's is the
  # organiser's to state.
  defp retold(component, known, address, allowed) do
    answers =
      for property <- known.properties,
          property.name == "ATTENDEE",
          property.value != address,
          into: %{},
          do: {property.value, property.parameters}

    properties =
      Enum.map(component.properties, fn property ->
        with "ATTENDEE" <- property.name,
             {:ok, theirs} <- Map.fetch(answers, property.value),
             answer when is_binary(answer) <- Map.get(theirs, "PARTSTAT") do
          # `RSVP=TRUE` is the question, not the answer. Somebody who
          # has replied is no longer being asked. An extension that
          # travels between participants travels here too: this is the
          # guest list as everyone else sees it.
          parameters =
            property.parameters
            |> Map.put("PARTSTAT", answer)
            |> Map.merge(travelling(theirs, allowed))

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
  defp separated(stored, replies, allowed) do
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
            do: accept(overridden(master, recurrence), [reply], allowed)
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
  defp replying(component, replies, spoken) do
    case matching(component, replies) do
      [] ->
        if component.name != "VTIMEZONE" and is_binary(value(component, "RECURRENCE-ID")),
          do: List.wrap(spoken),
          else: []

      found ->
        found
    end
  end

  defp matching(component, replies) do
    instance = value(component, "RECURRENCE-ID")

    Enum.filter(replies, &(value(&1, "RECURRENCE-ID") == instance))
  end

  defp accept(%{name: "VTIMEZONE"} = zone, _replies, _allowed), do: zone

  defp accept(component, replies, allowed) do
    answers =
      for reply <- replies,
          property <- reply.properties,
          property.name == "ATTENDEE",
          into: %{},
          do: {property.value, property.parameters}

    %{
      component
      | properties: Enum.map(component.properties, &participation(&1, answers, allowed))
    }
    |> carried(replies, allowed)
  end

  # An extension that travels between participants travels *back*. An
  # attendee's client may set one when it answers — "I will dial in",
  # say — and the organiser's copy is the only place the organiser's
  # client would look for it.
  defp carried(component, replies, allowed) do
    told =
      for reply <- replies,
          property <- reply.properties,
          travels?(property.name, allowed),
          into: %{},
          do: {property.name, property}

    # Replaced rather than merely added: an extension that travels
    # carries a *value*, and a copy left holding the previous one is
    # the stale answer rather than no answer.
    kept = Enum.reject(component.properties, &Map.has_key?(told, &1.name))

    %{component | properties: kept ++ Map.values(told)}
  end

  defp travels?(name, allowed) do
    String.starts_with?(name, "X-") and name not in @per_copy and not private?(name, allowed)
  end

  defp participation(%{name: "ATTENDEE", value: value} = property, replies, allowed) do
    case Map.fetch(replies, value) do
      {:ok, parameters} ->
        # "2.0" is iTIP's "request succeeded", which is what the
        # organiser's client shows as a confirmed attendee.
        # The reply's travelling parameters replace the stored set
        # rather than pile onto it — a parameter the attendee removed
        # is gone, the way the reference deletes a public parameter
        # the reply no longer carries.
        kept =
          for {name, value} <- property.parameters,
              not travels?(name, allowed),
              into: %{},
              do: {name, value}

        # `RSVP` falls away only when the answer moved — the
        # reference deletes it on a `PARTSTAT` change and otherwise
        # leaves the asking in place (`updateAttendeeDataFromReply`).
        answered_now =
          Map.get(parameters, "PARTSTAT", "NEEDS-ACTION") !=
            Map.get(property.parameters, "PARTSTAT", "NEEDS-ACTION")

        merged =
          kept
          |> Map.merge(Map.take(parameters, ["PARTSTAT"]))
          |> Map.merge(travelling(parameters, allowed))
          |> Map.put("SCHEDULE-STATUS", "2.0")

        %{
          property
          | parameters: if(answered_now, do: Map.delete(merged, "RSVP"), else: merged)
        }

      :error ->
        property
    end
  end

  defp participation(property, _replies, _allowed), do: property

  defp travelling(parameters, allowed) do
    for {name, value} <- parameters, travels?(name, allowed), into: %{}, do: {name, value}
  end

  # By UID, not by file name. A client names its own resources, and
  # `1.ics` holding an event whose UID is a long opaque string is the
  # normal case rather than the exception.
  defp cancel(calendar, components, uid, options, recipient) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, stored} <- ICalendar.parse(body) do
      withdrawn = for component <- components, do: utc_rid(component)

      cond do
        # The reference's `autoprocessing` branch: a whole-series
        # cancellation clears an auto-managed calendar outright — a
        # room keeps no strikethroughs, it just becomes free.
        unattended_recipient?(components, recipient, options) and nil in withdrawn ->
          remove(object, options)

        unattended_recipient?(components, recipient, options) ->
          quietly_cancelled(object, stored, withdrawn, components, recipient, options)

        true ->
          write(object, ICalendar.write(struck_through(stored, withdrawn, components)), options)
      end
    else
      _no_such_event -> :ok
    end
  end

  # What a cancellation leaves behind must still be a booking. A copy
  # holding nothing, or nothing but refusals, is not — the room's
  # calendar drops it rather than keeping a shell of turned-down
  # instances the organiser no longer holds it to.
  defp quietly_cancelled(object, stored, withdrawn, components, recipient, options) do
    remaining = excluded_quietly(stored, withdrawn, components)
    kept = Enum.filter(remaining.components, &(&1.name != "VTIMEZONE"))

    held? =
      Enum.any?(kept, fn component ->
        names?(component, canonical_address(recipient, options), options) and
          not declined_in?(component, recipient, options)
      end)

    if held?,
      do: write(object, ICalendar.write(remaining), options),
      else: remove(object, options)
  end

  # An attendee answers; they do not restate when the meeting
  # happens. A `DTSTART` re-spelt into another zone still names the
  # same instant, and the stored copy keeps the organiser's spelling —
  # the reference's attendee merge allows no change to the timing at
  # all, so the respelling is reverted rather than believed.
  defp in_held_zones(calendar, %{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        held = schedulable(before)
        components = Enum.map(calendar.components, &respelled_from(&1, held))

        if components == calendar.components do
          calendar
        else
          %{
            calendar
            | components:
                zones_for(components, calendar, before) ++
                  Enum.reject(components, &(&1.name == "VTIMEZONE"))
          }
        end

      _unreadable ->
        calendar
    end
  end

  defp in_held_zones(calendar, _change), do: calendar

  defp respelled_from(component, held) do
    with false <- component.name == "VTIMEZONE",
         %{} = counterpart <- Enum.find(held, &(utc_rid(&1) == utc_rid(component))) do
      respelled(component, counterpart)
    else
      _zone_or_new_component -> component
    end
  end

  defp respelled(component, held) do
    properties =
      Enum.map(component.properties, fn property ->
        with true <- property.name in ~w(DTSTART DTEND DUE),
             %{} = theirs <- Enum.find(held.properties, &(&1.name == property.name)),
             true <-
               utc_form(property.value, property.parameters) ==
                 utc_form(theirs.value, theirs.parameters) do
          theirs
        else
          _not_a_respelling -> property
        end
      end)

    %{component | properties: properties}
  end

  # The zones the copy still refers to, preferring the previously
  # stored definition — a reverted spelling needs the zone it was
  # reverted to.
  defp zones_for(components, calendar, before) do
    referenced =
      for component <- components,
          component.name != "VTIMEZONE",
          property <- component.properties,
          zone = Map.get(property.parameters, "TZID"),
          is_binary(zone),
          uniq: true,
          do: zone

    available =
      Enum.filter(before.components ++ calendar.components, &(&1.name == "VTIMEZONE"))

    for zone <- referenced,
        found = Enum.find(available, &(value(&1, "TZID") == zone)),
        not is_nil(found),
        do: found
  end

  defp held_rids(%{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} ->
        for component <- schedulable(before), do: utc_rid(component)

      _unreadable ->
        []
    end
  end

  defp held_rids(_change), do: []

  defp remove(object, %{store: store, context: context}) do
    if Store.supports?(store, :delete), do: store.delete(object, context)
    :ok
  end

  # Nobody reads a room's calendar for strikethroughs. An auto-managed
  # recipient takes the exclusion directly — the reference's
  # `autoprocessing` branch — freeing the time without ceremony.
  defp unattended_recipient?(components, recipient, %{store: store, context: context}) do
    Enum.any?(components, fn component ->
      Enum.any?(component.properties, &room?(&1, recipient))
    end) or (Store.supports?(store, :unattended?) and store.unattended?(recipient, context))
  end

  defp excluded_quietly(stored, withdrawn, components) do
    rids = Enum.filter(withdrawn, &is_binary/1)

    kept =
      stored.components
      |> Enum.map(&cancelled_if(&1, withdrawn -- rids, components))
      |> Enum.reject(&(&1.name != "VTIMEZONE" and utc_rid(&1) in rids))
      |> Enum.map(&excluding(&1, rids, components))

    # A copy held as one series — master and overrides together —
    # renumbers as one object; a copy of individually invited
    # instances holds each at its own version.
    serial? = Enum.any?(kept, &(&1.name != "VTIMEZONE" and is_nil(utc_rid(&1))))
    kept = Enum.map(kept, &numbered_if_risen(&1, components, serial?))

    %{stored | components: kept}
  end

  # The withdrawal carries the organiser's version and the quiet copy
  # takes it — upward only, and for the master even when the message
  # names no master: an instance-only cancellation still numbers the
  # round it closed.
  defp numbered_if_risen(%{name: "VTIMEZONE"} = zone, _sent, _serial?), do: zone

  defp numbered_if_risen(component, sent, serial?) do
    offered =
      case Enum.find(sent, &(&1.name != "VTIMEZONE" and utc_rid(&1) == utc_rid(component))) do
        %{} = counterpart ->
          sequence_of(counterpart)

        nil when serial? ->
          sent
          |> Enum.reject(&(&1.name == "VTIMEZONE"))
          |> Enum.map(&sequence_of/1)
          |> Enum.max(fn -> 0 end)

        nil ->
          0
      end

    if offered == sequence_of(component) + 1,
      do: restored(component, offered),
      else: component
  end

  defp excluding(component, rids, sent) do
    if component.name != "VTIMEZONE" and is_nil(value(component, "RECURRENCE-ID")) do
      held = utc_exclusion_set(component)

      # The exclusion is written the way the withdrawn instance names
      # itself — its own zone, not a UTC respelling the copy's other
      # dates never use.
      added =
        for offed <- sent,
            offed.name != "VTIMEZONE",
            rid = utc_rid(offed),
            is_binary(rid),
            rid in rids,
            rid not in held,
            %{} = identifier <- [Enum.find(offed.properties, &(&1.name == "RECURRENCE-ID"))],
            do: %{name: "EXDATE", parameters: identifier.parameters, value: identifier.value}

      %{component | properties: component.properties ++ added}
    else
      component
    end
  end

  defp rid_parameters(nil), do: %{}

  defp rid_parameters(component) do
    case Enum.find(component.properties, &(&1.name == "RECURRENCE-ID")) do
      %{parameters: found} -> found
      _bare -> %{}
    end
  end

  # A person gets the strikethrough. The cancelled override replaces
  # the exclusion on their copy — except for an instance they had
  # already excluded themselves, where the cancellation only confirms
  # a date they had let go, and the `EXDATE` stands.
  defp struck_through(stored, withdrawn, components) do
    already =
      case Enum.find(stored.components, fn component ->
             component.name != "VTIMEZONE" and is_nil(value(component, "RECURRENCE-ID"))
           end) do
        nil -> MapSet.new()
        master -> utc_exclusion_set(master)
      end

    fresh = Enum.reject(withdrawn, &(is_binary(&1) and &1 in already))
    marked = Enum.map(stored.components, &cancelled_if(&1, fresh, components))
    added = arrivals(marked, components, fresh)

    # The cancelled override *is* the exclusion on this copy. Keeping
    # the `EXDATE` beside it makes the master disclaim a component
    # the same object carries.
    %{
      stored
      | components:
          Enum.map(marked, &without_exclusions_for(&1, Enum.map(added, fn c -> utc_rid(c) end))) ++
            added
    }
  end

  defp cancelled_rids(components) do
    for component <- components,
        component.name != "VTIMEZONE",
        cancelled?(component),
        rid = utc_rid(component),
        is_binary(rid),
        do: rid
  end

  defp rids_of(components) do
    for component <- components, rid = value(component, "RECURRENCE-ID"), do: rid
  end

  defp without_exclusions_for(component, []), do: component

  defp without_exclusions_for(component, rids) do
    if is_nil(value(component, "RECURRENCE-ID")) do
      properties =
        component.properties
        |> Enum.map(&drop_excluded(&1, rids))
        |> Enum.reject(&is_nil/1)

      %{component | properties: properties}
    else
      component
    end
  end

  defp drop_excluded(%{name: "EXDATE", value: instances} = property, rids) do
    case instances
         |> String.split(",")
         |> Enum.reject(&(utc_form(&1, property.parameters) in rids)) do
      [] -> nil
      kept -> %{property | value: Enum.join(kept, ",")}
    end
  end

  defp drop_excluded(property, _rids), do: property

  # The instances an edit newly excludes, as derived components ready
  # to travel in a `CANCEL`. Each takes the master's properties with
  # the rule and its exceptions removed — they have been spent naming
  # this date — and states the occurrence it withdraws.
  defp called_off(components, change) do
    with %{} = master <- Enum.find(components, &is_nil(value(&1, "RECURRENCE-ID"))),
         [_ | _] = added <- added_exclusions(master, change) do
      for {parameters, instance} <- added, do: derived_instance(master, parameters, instance)
    else
      _nothing_newly_excluded -> []
    end
  end

  defp added_exclusions(master, change) do
    was = previous_master(change)
    held = if was, do: exclusion_set(was), else: MapSet.new()

    # Only a date the previous rule actually produced is withdrawn by
    # excluding it. An exclusion arriving in the same save that first
    # creates the occurrence — a rule expanded and pre-trimmed at once
    # — names a meeting nobody ever had, and cancelling it would be
    # the recipient's first news of it.
    for property <- master.properties,
        property.name == "EXDATE",
        instance <- String.split(property.value, ","),
        instance not in held,
        was != nil and TimeRange.occurs?(was, property.parameters, instance),
        do: {property.parameters, instance}
  end

  defp previous_master(%{previous: previous}) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, before} -> Enum.find(schedulable(before), &is_nil(value(&1, "RECURRENCE-ID")))
      _unreadable -> nil
    end
  end

  defp previous_master(_change), do: nil

  defp exclusion_set(master) do
    for property <- master.properties,
        property.name == "EXDATE",
        instance <- String.split(property.value, ","),
        into: MapSet.new(),
        do: instance
  end

  defp derived_instance(master, parameters, instance) do
    kept =
      Enum.reject(master.properties, &(&1.name in ~w(RRULE RDATE EXDATE DTSTART RECURRENCE-ID)))

    stated = [
      %{name: "DTSTART", parameters: parameters, value: instance},
      %{name: "RECURRENCE-ID", parameters: parameters, value: instance}
    ]

    %{master | properties: stated ++ kept, components: []}
  end

  # A cancelled instance the recipient holds no override for is added,
  # not ignored. Their copy carries the series as a rule; the one
  # Tuesday that was called off needs a component of its own to say so,
  # and the reference derives one for exactly this (`processCancel`,
  # the no-override branch). The message's component *is* that derived
  # instance — the sender built it from the master — so it is taken as
  # sent, marked cancelled, already carrying its version.
  defp arrivals(marked, sent, withdrawn) do
    held =
      for component <- marked, component.name != "VTIMEZONE", rid = utc_rid(component), do: rid

    master? = Enum.any?(marked, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    master =
      Enum.find(marked, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    for component <- sent,
        component.name != "VTIMEZONE",
        rid = utc_rid(component),
        is_binary(rid),
        rid in withdrawn,
        rid not in held,
        master?,
        do: component |> cancelled(nil) |> inheriting(master)
  end

  # What this copy already said carries onto the new instance: the
  # holder's participation, and the record that their reply was
  # delivered, live on their master and are theirs — the message was
  # shaped for sending and stripped of both.
  defp inheriting(component, nil), do: component

  defp inheriting(component, master) do
    known =
      for property <- master.properties,
          property.name in ~w(ATTENDEE ORGANIZER),
          into: %{},
          do: {{property.name, property.value}, property.parameters}

    properties =
      Enum.map(component.properties, fn property ->
        case Map.fetch(known, {property.name, property.value}) do
          {:ok, parameters} ->
            %{property | parameters: Map.merge(property.parameters, parameters)}

          :error ->
            property
        end
      end)

    %{component | properties: properties}
  end

  # A `CANCEL` names the instances it withdraws. One carrying the
  # master — a component with no `RECURRENCE-ID` — withdraws the whole
  # series; one naming a single override leaves the rest standing.
  # Cancelling everything regardless cleared an attendee's calendar of
  # meetings that are still going ahead.
  defp cancelled_if(%{name: "VTIMEZONE"} = zone, _withdrawn, _sent), do: zone

  defp cancelled_if(component, withdrawn, sent) do
    if nil in withdrawn or utc_rid(component) in withdrawn,
      do: component |> cancelled(nil) |> numbered(sent),
      else: component
  end

  # The withdrawal carries its own version, and the copy it cancels
  # takes it. A recipient left holding the version they were invited
  # at cannot tell a cancellation from the invitation it withdraws.
  defp numbered(component, sent) do
    with %{} = counterpart <-
           Enum.find(sent, &(utc_rid(&1) == utc_rid(component))) ||
             Enum.find(sent, &is_nil(value(&1, "RECURRENCE-ID"))),
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
  defp preserving(calendar, recipient, components, announced, uid, options) do
    with %Resource{} = object <- object_with(calendar, uid, options),
         {:ok, body} <- read(object, options),
         {:ok, existing} <- ICalendar.parse(body) do
      held = schedulable(existing)

      if agent_switched?(held, components) do
        # The copy they hold was never the server's to schedule — its
        # organiser was marked `SCHEDULE-AGENT=NONE` when they stored
        # it themselves — and the invitation now arriving is a
        # different arrangement entirely. The reference throws the
        # existing data away and starts from the message
        # (`processRequest`, the schedule-agent change check).
        invited_to(components, recipient, options)
      else
        preserved(calendar, recipient, components, announced, held, options)
      end
    else
      _no_previous_copy -> arrived_fresh(components, recipient, options)
    end
  end

  # A first delivery carries no history to merge — but it still obeys
  # the missing-declined rule: with no master in the message, an
  # instance that already shows the recipient `DECLINED` is one they
  # refused, and it does not reappear in a copy they no longer hold
  # (`transferItems`, the missing-declined return).
  defp arrived_fresh(components, recipient, options) do
    invited = invited_to(components, recipient, options)

    master? =
      Enum.any?(invited, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    cond do
      master? ->
        invited

      # A room's *freshly* declined booking is still written down: its
      # calendar records what it just turned down, transparent. A
      # refusal it gave in an earlier round is a copy it already shed —
      # the reference ignores an arrival that is nothing but old
      # declines rather than recreating it.
      auto_managed?(recipient, options) ->
        if canonical_address(recipient, options) in Map.get(options, :auto_replied, []),
          do: invited,
          else: Enum.reject(invited, &declined_in?(&1, recipient, options))

      true ->
        Enum.reject(invited, &declined_in?(&1, recipient, options))
    end
  end

  defp agent_switched?(held, components) do
    organizer_agent(held) != organizer_agent(components)
  end

  defp organizer_agent(components) do
    Enum.find_value(components, "SERVER", &agent_of_component/1)
  end

  defp agent_of_component(component) do
    Enum.find_value(component.properties, fn property ->
      if property.name == "ORGANIZER",
        do: Map.get(property.parameters, "SCHEDULE-AGENT", "SERVER")
    end)
  end

  defp preserved(calendar, recipient, components, announced, held, options) do
    _ = calendar

    (
      # Two questions, not one. If the *series* moved — its `DTSTART`
      # or its rule — everyone is being asked again, overrides
      # included, however little each one changed on its own. If it
      # did not, then only the occurrences that moved re-ask, and a
      # series that merely gained an exception leaves every other
      # answer standing.
      asked_anew = reasked?(master_of(components), held)

      kept =
        if asked_anew,
          do: Enum.map(components, &carry_organizer(&1, held)),
          else: Enum.map(components, &answered_before(&1, recipient, held))

      # A rescheduled series redraws its own exclusions: the message's
      # `EXDATE`s describe the new timing, and carrying the old copy's
      # would exclude instants the new rule never produces.
      exclusions = if asked_anew, do: [], else: held

      kept
      |> Enum.map(&without_exclusions_for(&1, cancelled_rids(held)))
      |> Enum.map(&carry_alarms(&1, held))
      |> Enum.map(&carry_transparency(&1, held))
      |> Enum.map(&carry_private(&1, held))
      |> Enum.map(&carry_reply_record(&1, held))
      |> Enum.map(&carry_exclusions(&1, exclusions))
      |> only_announced(held, announced, recipient, options)
      |> readmitted(announced, recipient, options)
      |> Enum.map(&reinstated(&1, Map.get(options, :created, [])))
      |> unexcluded()
      |> Enum.map(&asked_afresh(&1, recipient, options))
    )
  end

  # A forced re-invitation overrules the carried answer: the organiser
  # asked again, so the recipient's copy shows the question, not the
  # answer they gave last time.
  defp asked_afresh(component, recipient, options) do
    if canonical_address(recipient, options) in Map.get(options, :reinvited, []),
      do: reasked_by_force(component, [canonical_address(recipient, options)], options),
      else: component
  end

  # A first invitation carries only what the recipient was invited to.
  # Somebody added to one occurrence of a series holds that occurrence:
  # handing them the master as well puts the whole series in their
  # calendar, nearly all of which they were never asked about — and
  # their client then shows a daily meeting where one Tuesday was
  # meant.
  defp invited_to(components, recipient, options) do
    address = canonical_address(recipient, options)

    case Enum.filter(components, &names?(&1, address, options)) do
      [] -> components
      invited -> invited
    end
  end

  defp names?(component, address, options) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and addressed_as(property, options) == address
    end)
  end

  # An update changes the instances it announces and leaves the rest of
  # the recipient's copy alone. What they hold for an instance nobody
  # is telling them about is theirs — an occurrence they took out of
  # their own copy stays out, and rebuilding the whole series from the
  # message puts every one of them back each time the organiser edits
  # a word.
  # An override arriving in an update re-admits its instance. The
  # recipient may have excluded that date themselves — declining it —
  # and the organiser asking again supersedes the refusal: their
  # master cannot keep disclaiming a component the same object now
  # carries. The reference removes the matching `EXDATE` whenever it
  # adds an override from a message (`processRequest`).
  # Only an override that *asks* the recipient lifts their own
  # exclusion: they declined that date, and an update that still
  # shows them declined does not overrule the refusal. One that puts
  # the question back — a moved instance, a forced re-invitation, a
  # place they were newly given — arrives reading `NEEDS-ACTION`, and
  # the returned instance replaces the `EXDATE`.
  defp readmitted(kept, announced, recipient, options) do
    address = canonical_address(recipient, options)

    arrived =
      for component <- announced,
          component.name != "VTIMEZONE",
          rid = utc_rid(component),
          is_binary(rid),
          asking_again?(component, address, options),
          do: rid

    Enum.map(kept, &without_exclusions_for(&1, arrived))
  end

  defp asking_again?(component, address, options) do
    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and addressed_as(property, options) == address and
        Map.get(property.parameters, "PARTSTAT", "NEEDS-ACTION") == "NEEDS-ACTION"
    end)
  end

  defp only_announced(kept, [], _announced, _recipient, _options), do: kept

  defp only_announced(kept, held, announced, recipient, options) do
    ids = MapSet.new(announced, &value(&1, "RECURRENCE-ID"))

    revised =
      for component <- kept,
          value(component, "RECURRENCE-ID") in ids,
          into: %{},
          do: {value(component, "RECURRENCE-ID"), component}

    theirs =
      for component <- held,
          survivor =
            (case Map.get(revised, value(component, "RECURRENCE-ID")) do
               nil -> restated_from(component, Map.get(revised, nil), held)
               replacement -> replacement
             end),
          not is_nil(survivor),
          do: survivor

    known = MapSet.new(held, &value(&1, "RECURRENCE-ID"))

    # An instance they do not hold is added back — unless the message
    # itself still shows them declined for it. Their copy dropped that
    # occurrence because they refused it, and an update that does not
    # re-ask does not undo the refusal; one that re-invites carries
    # them as `NEEDS-ACTION` and the instance returns. The reference
    # draws the same line (`transferItems`, the missing-declined
    # return).
    # The declined-instance drop is the masterless update's rule: with
    # no master, an instance the recipient declined out of their copy
    # stays out (`transferItems`, the missing-declined return). A
    # message that carries the master rebuilds the copy wholesale, and
    # every override travels with it — a decliner who kept the event
    # still sees its instances change shape.
    with_master? =
      Enum.any?(kept, &(&1.name != "VTIMEZONE" and is_nil(value(&1, "RECURRENCE-ID"))))

    theirs ++
      for {instance, component} <- revised,
          instance not in known,
          with_master? or not declined_in?(component, recipient, options),
          do: component
  end

  # An update that carries the master replaces the recipient's copy
  # wholesale, and an override the message no longer mentions is
  # re-derived from the new master — at the recurrence's own time,
  # with the new attendee list and version — rather than kept as it
  # was. The reference does this with `deriveInstance`; keeping the
  # stale override leaves the recipient holding a meeting shaped like
  # the series that no longer exists. A cancelled override stays as
  # it is (`allowCancelled`), and when the series was not rescheduled
  # the recipient's answers carry onto the derived instance.
  defp restated_from(component, nil, _held), do: component
  defp restated_from(%{name: "VTIMEZONE"} = zone, _master, _held), do: zone

  defp restated_from(component, master, held) do
    rid = value(component, "RECURRENCE-ID")

    cond do
      is_nil(rid) ->
        component

      cancelled?(component) ->
        component

      # An instance the new rule no longer produces is not re-derived
      # — it is gone, the way the reference's `deriveInstance` returns
      # nothing for a date outside the rule. A truncated series takes
      # its truncated overrides with it.
      not TimeRange.occurs?(master, rid_parameters(component), rid) ->
        nil

      true ->
        derived = derived_instance(master, rid_parameters(component), rid)

        derived
        |> answered_unless_reasked(component, master, held)
        |> carry_alarms(held)
        |> carry_transparency(held)
    end
  end

  defp answered_unless_reasked(derived, component, master, held) do
    if reasked?(master, held), do: derived, else: inheriting(derived, component)
  end

  defp declined_in?(component, recipient, options) do
    address = canonical_address(recipient, options)

    Enum.any?(component.properties, fn property ->
      property.name == "ATTENDEE" and addressed_as(property, options) == address and
        Map.get(property.parameters, "PARTSTAT") == "DECLINED"
    end)
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

  # The record that a reply reached the organiser belongs to the
  # *copy*, not to one occurrence of it: the `SCHEDULE-STATUS` on the
  # `ORGANIZER` line says what became of the last reply sent from this
  # copy, and every component carries the same answer. A component
  # restored without it — one the recipient never replied about —
  # takes the record the rest of the copy already shows.
  defp carry_reply_record(%{name: "VTIMEZONE"} = zone, _held), do: zone

  defp carry_reply_record(component, held) do
    delivery = Enum.find_value(held, &reply_record_of/1)

    if is_nil(delivery) do
      component
    else
      properties = Enum.map(component.properties, &recorded_delivery(&1, delivery))

      %{component | properties: properties}
    end
  end

  defp reply_record_of(component) do
    Enum.find_value(component.properties, fn property ->
      if property.name == "ORGANIZER", do: Map.get(property.parameters, "SCHEDULE-STATUS")
    end)
  end

  defp recorded_delivery(%{name: "ORGANIZER"} = property, delivery),
    do: %{property | parameters: Map.put_new(property.parameters, "SCHEDULE-STATUS", delivery)}

  defp recorded_delivery(property, _delivery), do: property

  # The recipient's own bookkeeping — travel time, needs-reply flags —
  # lives on their copy and nowhere else. The reference removes these
  # from every incoming message and restores the stored ones
  # (`PerAttendeeProperties` in `_transferItems`).
  defp carry_private(component, held) do
    case counterpart_or_series(component, held) do
      nil ->
        component

      previous ->
        kept = Enum.filter(previous.properties, &(&1.name in @per_copy))
        cleared = Enum.reject(component.properties, &(&1.name in @per_copy))

        %{component | properties: cleared ++ kept}
    end
  end

  # `TRANSP` belongs to whoever holds the copy. An attendee who
  # declined and marked the time free is not made busy again because
  # the organiser saved an edit — their calendar would show them
  # booked for a meeting they had said no to.
  defp carry_transparency(component, held) do
    with previous when not is_nil(previous) <- counterpart_or_series(component, held),
         %{} = theirs <- Enum.find(previous.properties, &(&1.name == "TRANSP")) do
      %{component | properties: restated_transparency(component.properties, theirs)}
    else
      _none_of_their_own -> component
    end
  end

  # The occurrence they hold, or failing that the series. An override
  # the organiser has just added is new to the recipient, so there is
  # nothing of theirs on that occurrence — but they marked the series
  # free, and an exception to a meeting they are not attending is
  # still one they are not attending.
  defp counterpart_or_series(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence)) ||
      Enum.find(held, &is_nil(value(&1, "RECURRENCE-ID")))
  end

  defp restated_transparency(properties, theirs) do
    case Enum.find_index(properties, &(&1.name == "TRANSP")) do
      nil -> properties ++ [theirs]
      index -> List.replace_at(properties, index, theirs)
    end
  end

  # An occurrence that is excluded has no override: the two say
  # opposite things about the same date, and a copy holding both shows
  # a meeting the same copy says is not happening.
  defp unexcluded(components) do
    excluded =
      for component <- components,
          is_nil(value(component, "RECURRENCE-ID")),
          property <- component.properties,
          property.name == "EXDATE",
          instance <- String.split(property.value, ","),
          into: MapSet.new(),
          do: instance

    # A cancelled override is *why* the date is excluded, and stays: the
    # recipient's client shows the strikethrough and lets them tidy it
    # away themselves. The reference preserves exactly this pairing
    # (`allowCancelled` in `processRequest`); only a live override on
    # an excluded date is the contradiction this exists to remove.
    Enum.reject(components, fn component ->
      value(component, "RECURRENCE-ID") in excluded and not cancelled?(component)
    end)
  end

  # An occurrence the recipient has excluded stays excluded. Declining
  # one Tuesday is done by taking it out of your own copy, and an
  # update to the series that put it back would have them turning it
  # down again every time the organiser edited the summary.
  # An occurrence the organiser has just written an override for is
  # one they are putting back on, and the exclusion the recipient
  # holds for it goes. This runs after the recipient's own components
  # are merged back in, because the exclusion lives on a master the
  # merge may have kept untouched.
  defp reinstated(component, []), do: component

  defp reinstated(component, reinvited) do
    kept =
      Enum.reject(component.properties, &(&1.name == "EXDATE" and &1.value in reinvited))

    %{component | properties: kept}
  end

  defp carry_exclusions(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    case Enum.find(held, &(value(&1, "RECURRENCE-ID") == recurrence)) do
      nil ->
        component

      previous ->
        known =
          for property <- component.properties, property.name == "EXDATE", do: property.value

        theirs =
          for property <- previous.properties,
              property.name == "EXDATE",
              property.value not in known,
              do: property

        %{component | properties: component.properties ++ theirs}
    end
  end

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
  defp master_of(components), do: Enum.find(components, &is_nil(value(&1, "RECURRENCE-ID")))

  # No master in the message means nothing was said about the series
  # as a whole.
  defp reasked?(nil, _held), do: false
  defp reasked?(master, held), do: asked_again?(master, held)

  # An occurrence the recipient does not hold is not one they have
  # answered: it is new to them, or one they took out of their own copy
  # and the organiser has just put back. Either way the organiser's
  # values stand, and looking for an answer that was never given leaves
  # the occurrence carrying nothing.
  defp answered_before(component, recipient, held) do
    if asked_again?(component, held) or excluded_by?(component, held),
      do: carry_organizer(component, held),
      else: carry_over(component, recipient, held)
  end

  # An occurrence the recipient took out of their own copy, and the
  # organiser has put back, is one they are being asked about again —
  # their exclusion *was* their answer, and it has been overruled. An
  # occurrence that is merely new to them is a different thing: they
  # answered the series, and the organiser adding an exception does
  # not withdraw that answer.
  defp excluded_by?(component, held) do
    recurrence = value(component, "RECURRENCE-ID")

    is_binary(recurrence) and Enum.any?(held, &excludes?(&1, recurrence))
  end

  defp excludes?(component, recurrence) do
    is_nil(value(component, "RECURRENCE-ID")) and
      Enum.any?(component.properties, fn property ->
        property.name == "EXDATE" and recurrence in String.split(property.value, ",")
      end)
  end

  # The recipient's *own* participation, and the ORGANIZER status
  # recording that their reply was delivered — and nothing else. What
  # the other attendees have since answered is the organiser's to say,
  # and keeping this copy's stale view of them would tell each
  # attendee that everyone else is still undecided.
  # The answer restored is the one given for *this occurrence* — an
  # attendee who accepted the series and declined one Friday said two
  # different things, and pouring every held answer into one map let
  # whichever came last speak for both. An occurrence with no stored
  # counterpart falls back to the master's answer: they answered the
  # series, and a new exception does not withdraw that.
  defp carry_over(component, recipient, existing) do
    recurrence = value(component, "RECURRENCE-ID")

    held =
      Enum.find(existing, &(value(&1, "RECURRENCE-ID") == recurrence)) ||
        Enum.find(existing, &is_nil(value(&1, "RECURRENCE-ID")))

    kept =
      for old <- List.wrap(held),
          property <- old.properties,
          property.name == "ORGANIZER" or property.value == recipient,
          property.name in ~w(ATTENDEE ORGANIZER),
          into: %{},
          do: {{property.name, property.value}, property.parameters}

    %{component | properties: Enum.map(component.properties, &restore(&1, kept))}
  end

  defp restore(%{name: name} = property, kept)
       when name in ~w(ATTENDEE ORGANIZER) do
    # A marked line is the question being re-put: the organiser reset
    # this attendee on purpose, and the stored answer must not climb
    # back over it.
    if Map.has_key?(property.parameters, "X-CALENDARSERVER-RESET-PARTSTAT") do
      property
    else
      answer_restored(property, kept)
    end
  end

  defp restore(property, _kept), do: property

  defp answer_restored(%{name: name, value: value} = property, kept) do
    case Map.fetch(kept, {name, value}) do
      {:ok, parameters} ->
        %{property | parameters: settled(Map.merge(property.parameters, taken(parameters)))}

      :error ->
        property
    end
  end

  # `RSVP=TRUE` is the question, not the answer. Restoring somebody's
  # participation restores what they said; leaving the request for a
  # reply beside it has their client go on showing an invitation they
  # have already answered.
  defp settled(parameters) do
    case Map.get(parameters, "PARTSTAT") do
      answer when answer in [nil, "NEEDS-ACTION"] -> parameters
      _answered -> Map.delete(parameters, "RSVP")
    end
  end

  defp taken(parameters), do: Map.take(parameters, ["PARTSTAT", "SCHEDULE-STATUS"])

  defp own_copy(components, zones, recipient) do
    ICalendar.write(%{
      name: "VCALENDAR",
      properties: [
        %{name: "VERSION", parameters: %{}, value: "2.0"},
        %{name: "PRODID", parameters: %{}, value: "-//Dav//CalDAV//EN"}
      ],
      components:
        zones ++
          (components
           |> Enum.map(&untaken(&1, recipient))
           |> answered_back(recipient))
    })
  end

  # The server answered on the room's behalf only if there was
  # something to answer: an event wholly in the past, or one the
  # room's mode held its peace on, was delivered and left alone — its
  # copy records no reply the organiser never got.
  defp answered_back(components, recipient) do
    answered? =
      Enum.any?(components, fn component ->
        component.name != "VTIMEZONE" and
          Enum.any?(component.properties, fn property ->
            property.name == "ATTENDEE" and property.value == recipient and
              Map.get(property.parameters, "PARTSTAT") in ["ACCEPTED", "DECLINED"]
          end)
      end)

    if answered?,
      do: Enum.map(components, &replied(&1, recipient)),
      else: components
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
  Whether a resource may be removed by the requesting principal.

  A sharee with write access may edit their own view of an
  organiser's event — `TRANSP`, alarms, `X-` data — but deleting it
  cancels a meeting belonging to the organiser and the people
  invited, none of whom they are. The reference refuses the removal
  outright rather than quietly cancelling on a stranger's behalf.

  ### Arguments

  * `resource` is the resource the request asks to delete.

  * `collection` is its parent collection, or `nil`.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok` for anything but a scheduling object being removed by
    somebody who is neither its owner nor a participant.

  * `{:error, {\"DAV:\", \"need-privileges\"}}` otherwise.

  """
  @impl Dav.Web.Hook
  @spec removable(Resource.t(), Resource.t() | nil, map()) ::
          :ok | {:error, {String.t(), String.t()}}
  def removable(%Resource{collection?: true}, _collection, _options), do: :ok

  def removable(resource, %Resource{} = collection, options) do
    with {:ok, body} <- read(resource, options),
         {:ok, calendar} <- ICalendar.parse(body),
         [_ | _] = components <- schedulable(calendar),
         organizer when is_binary(organizer) <- organizer_of(components),
         owner when is_binary(owner) <- shared_from(collection, options) || collection.owner,
         who when is_binary(who) and who != owner <- Map.get(options, :principal),
         false <- involved_in?(components, who, options) do
      {:error, {Xml.dav(), "need-privileges"}}
    else
      _their_own_or_unscheduled -> :ok
    end
  end

  def removable(_resource, _collection, _options), do: :ok

  defp involved_in?(components, principal, %{store: store, context: context} = options) do
    with true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(principal, context) do
      canonical = Enum.map(addresses, &canonical_address(&1, options))

      Enum.any?(components, &names_any?(&1, canonical, options))
    else
      # With no way to name the requester, refusing would lock out
      # legitimate participants — the plain access rules stand alone.
      _no_lookup -> true
    end
  end

  defp names_any?(component, canonical, options) do
    Enum.any?(component.properties, fn property ->
      property.name in ~w(ATTENDEE ORGANIZER) and
        canonical_address(property.value, options) in canonical
    end)
  end

  defp shared_from(collection, %{store: store, context: context}) do
    with true <- Store.supports?(store, :origin),
         real when real != collection.path <- store.origin(collection.path, context),
         {:ok, %Resource{owner: owner}} <- store.resolve(real, context) do
      owner
    else
      _not_a_link -> nil
    end
  end

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

  # Whose calendar this really is. A calendar shared into somebody's
  # home is a *view* of the sharer's: the collection at that path is
  # owned by the invitee, but the events in it are scheduled for the
  # sharer — a sharee's save must not be read as the sharee answering.
  defp owner_addresses(%Resource{} = collection, %{store: store, context: context} = options) do
    case shared_from(collection, options) || collection.owner do
      nil ->
        []

      owner ->
        # Without an explicit lookup the principal URL is all there
        # is, and comparing it against an `ORGANIZER` of `mailto:...`
        # would never match — so scheduling is skipped rather than
        # guessed at.
        with true <- function_exported?(store, :addresses, 2),
             {:ok, addresses} <- store.addresses(owner, context) do
          addresses
        else
          _no_lookup -> []
        end
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

  # Where a delivered event may land: a calendar that holds events. A
  # calendar declaring `CALDAV:supported-calendar-component-set`
  # without `VEVENT` — the tasks calendar — is not a home for an
  # invitation, however first it sits in the listing.
  defp event_calendar?(resource, %{store: store, context: context}) do
    Cal.calendar?(resource) and
      case Store.supports?(store, :properties) and
             Map.get(
               store.properties(resource, context),
               {Xml.caldav(), "supported-calendar-component-set"}
             ) do
        {:components, names} -> "VEVENT" in names
        _undeclared -> true
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
      # Into the copy they already hold, wherever their client put it:
      # writing to a derived name beside it would leave two resources
      # claiming one meeting, which `unique-scheduling-object-resource`
      # exists to forbid. Only a copy that *is* the meeting counts —
      # an unorganised event that merely shares the `UID` is a private
      # appointment, and the invitation lands beside it.
      path =
        with %Resource{path: existing} = object <- object_with(collection, uid, options),
             {:ok, held} <- read(object, options),
             {:ok, stored} <- ICalendar.parse(held),
             organizer when is_binary(organizer) <- organizer_of(schedulable(stored)) do
          existing
        else
          _no_scheduling_copy -> collection.path ++ [(uid || "message") <> ".ics"]
        end

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
  defp tag(resource, body, %{store: store, context: context} = options) do
    if scheduling_body?(body) and Store.supports?(store, :patch) do
      operations = [
        {:set, schedule_tag(), fresh_tag(body)} | reset_etags(resource, body, options)
      ]

      store.patch(resource, operations, context)
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
