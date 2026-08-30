defmodule Dav.Cal.Object do
  @moduledoc """
  What a calendar object resource is allowed to be — RFC 4791 sections
  4.1 and 5.3.2.

  A calendar collection is not a filesystem that happens to hold
  iCalendar. The specification constrains what may be stored, and a
  server that skips the checks corrupts its own collections: two
  components sharing a `UID` in different resources make the recurrence
  set unaddressable, and a stored `METHOD` turns a calendar entry into
  a scheduling message that will be replayed as one.

  ### The restrictions

  From section 4.1, a calendar object resource:

  * MUST NOT contain more than one type of component, except that
    `VTIMEZONE` may accompany any of them;
  * MUST NOT specify the `METHOD` property;
  * MUST have one `UID` across all its components — differing `UID`s
    belong in separate resources;
  * MUST NOT reuse a `UID` already stored elsewhere in the collection.

  ### Preconditions, not opinions

  Each failure names the precondition the specification gives it, so a
  `403` says which rule was broken rather than merely refusing. That is
  the difference between a client that can correct itself and one that
  can only guess.

  """

  @behaviour Dav.Web.Validator

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Scheduling
  alias Dav.Cal.Sharing
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml
  alias Tempo.RRule

  # Components that carry a UID and define what kind of object this is.
  # VTIMEZONE is excluded deliberately: it accompanies any of them.
  @scheduling ~w(VEVENT VTODO VJOURNAL VFREEBUSY VPOLL)

  # RFC 4791 section 5.2.9 leaves the value to the server. This one is
  # generous enough never to trouble a real invitation and small enough
  # to refuse an abusive one.
  @max_attendees 100

  @typedoc "The precondition that failed, as a qualified name."
  @type violation :: Xml.qname()

  @doc """
  Check a body against the calendar object resource restrictions.

  ### Arguments

  * `body` is the request body.

  * `collection` is the target calendar collection.

  * `path` is the path being written, so that overwriting a resource
    with its own `UID` is not mistaken for a conflict.

  * `options` carries `:store` and `:context`, for the `UID` check
    against what the collection already holds.

  ### Returns

  * `:ok`; or

  * `{:error, precondition}` naming the CalDAV precondition that
    failed.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nMETHOD:REQUEST\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> Dav.Cal.Object.validate(ics, nil, [], %{})
      {:error, {"urn:ietf:params:xml:ns:caldav", "valid-calendar-object-resource"}}

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nEND:VEVENT\\r\\nBEGIN:VTODO\\r\\nUID:1\\r\\nEND:VTODO\\r\\nEND:VCALENDAR\\r\\n"
      iex> Dav.Cal.Object.validate(ics, nil, [], %{})
      {:error, {"urn:ietf:params:xml:ns:caldav", "valid-calendar-object-resource"}}

      iex> Dav.Cal.Object.validate("not a calendar", nil, [], %{})
      {:error, {"urn:ietf:params:xml:ns:caldav", "valid-calendar-data"}}

  """
  @impl Dav.Web.Validator
  @spec validate(binary(), Resource.t() | nil, [String.t()], map()) ::
          :ok | {:error, violation()}
  def validate(body, collection, path, options) do
    with :ok <- permitted(collection, options),
         :ok <- media_type(options),
         :ok <- printable(body),
         {:ok, calendar} <- parse(body),
         :ok <- unreserved(calendar),
         :ok <- structure(calendar),
         :ok <- readable_values(calendar),
         :ok <- timezones_present(calendar),
         :ok <- within_limits(calendar),
         :ok <- unique_uid(calendar),
         :ok <- attendee_allowed(calendar, collection, path, options),
         :ok <- organizer_allowed(calendar, collection, options),
         :ok <- agent_unchanged(calendar, collection, path, options),
         :ok <- same_organizer(calendar, path, options) do
      no_uid_conflict(calendar, collection, path, options)
    end
  end

  # A calendar shared read-only may be read. Writing to it is refused
  # here rather than accepted and quietly dropped, because a client
  # that believes its write succeeded shows the user an event nobody
  # else can see.
  defp permitted(collection, options) do
    if Sharing.writable?(collection, options),
      do: :ok,
      else: {:error, precondition("need-privileges")}
  end

  # A server that keeps one person's alarms and transparency apart
  # from everyone else's stores them in components of its own. Those
  # are its private bookkeeping, and a client that sends them is
  # writing another user's data into an event — so the body is
  # refused rather than stored and silently believed.
  @reserved ~w(X-CALENDARSERVER-PERUSER X-CALENDARSERVER-PERINSTANCE)

  defp unreserved(calendar) do
    if Enum.any?(calendar.components, &(&1.name in @reserved)),
      do: {:error, precondition("valid-calendar-data")},
      else: :ok
  end

  # A body that is not iCalendar at all fails a different precondition
  # from one that is iCalendar and wrong. `supported-calendar-data`
  # says "this server does not take that media type"; a client sending
  # vCard to a calendar needs to hear that rather than being told its
  # calendar data is invalid.
  defp media_type(options) do
    case Map.get(options, :content_type) do
      nil ->
        :ok

      type ->
        if calendar_type?(type), do: :ok, else: {:error, precondition("supported-calendar-data")}
    end
  end

  defp calendar_type?(type) do
    type |> String.split(";") |> List.first() |> String.trim() |> String.downcase() ==
      "text/calendar"
  end

  defp parse(body) do
    case ICalendar.parse(body) do
      {:ok, %{name: "VCALENDAR"} = calendar} -> {:ok, calendar}
      _unreadable -> {:error, precondition("valid-calendar-data")}
    end
  end

  # Control characters are forbidden by RFC 5545 section 3.1, and the
  # check belongs on the raw body rather than on parsed values: the
  # reader has already turned `\\n` into a real newline by then, so a
  # decoded value cannot be told from one that carried a raw control
  # character on the wire. Only CR, LF and tab survive here, because
  # those are the line structure itself.
  defp printable(body) do
    cond do
      # iCalendar is UTF-8 (RFC 5545 section 6). Bytes that are not
      # valid UTF-8 are not merely unusual — nothing downstream can
      # read them, and a regex over them does not mean what it looks
      # like it means.
      not String.valid?(body) ->
        {:error, precondition("valid-calendar-data")}

      controls?(body) ->
        {:error, precondition("valid-calendar-data")}

      malformed_escape?(body) ->
        {:error, precondition("valid-calendar-data")}

      true ->
        :ok
    end
  end

  # Checked byte by byte rather than by regex: the forbidden set is the
  # C0 controls, and every byte of a multi-byte UTF-8 character is
  # 0x80 or above, so no accented letter can be mistaken for one.
  defp controls?(body) do
    body
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 0x20 and &1 not in [?\t, ?\r, ?\n]))
  end

  # In a TEXT value only `\\\\`, `\;`, `\\,`, `\\n` and `\\N` are escapes. The
  # rule applies to the *value* of a TEXT property and nowhere else:
  # parameter values escape differently (RFC 6868 uses `^`), so
  # `X-APPLE-ABUID=ab\\://Work` is a legal parameter that a whole-body
  # scan reads as a broken escape.
  #
  # It still has to look at the raw line, because by the time the
  # reader has finished a malformed escape is indistinguishable from a
  # literal backslash it decoded on purpose.
  @text_valued ~w(SUMMARY DESCRIPTION LOCATION COMMENT CONTACT
                  CATEGORIES RESOURCES RELATED-TO TZNAME)

  defp malformed_escape?(body) do
    body
    |> String.replace("\r\n ", "")
    |> String.split(~r/\r?\n/)
    |> Enum.any?(&bad_line?/1)
  end

  defp bad_line?(line) do
    case String.split(line, ":", parts: 2) do
      [head, value] -> text_property?(head) and stray_backslash?(value)
      _no_value -> false
    end
  end

  defp text_property?(head) do
    name = head |> String.split(";") |> List.first()

    name in @text_valued
  end

  # Valid pairs are consumed first, then any backslash still standing
  # began a sequence that is not an escape. Matching "a backslash not
  # followed by a legal character" instead gets `\\\\e` wrong: it pairs
  # the second backslash with the `e`.
  defp stray_backslash?(value) do
    value
    |> String.replace(~r/\\[\\;,nN]/, "")
    |> String.contains?("\\")
  end

  # An `RRULE` that cannot be parsed describes no recurrence, and a
  # server that stores it hands the client back something no reader can
  # expand. This asks only whether the rule is *readable* — a rule this
  # server cannot yet expand is still valid data, and refusing it would
  # reject correct clients.
  defp readable_values(calendar) do
    calendar
    |> every_component()
    |> Enum.flat_map(& &1.properties)
    |> Enum.filter(&(&1.name in ["RRULE", "RECURRENCE-ID"]))
    |> Enum.reduce_while(:ok, fn property, _outcome ->
      if readable?(property),
        do: {:cont, :ok},
        else: {:halt, {:error, precondition("valid-calendar-data")}}
    end)
  end

  defp readable?(%{name: "RRULE", value: value}), do: recurrence?(value)

  # A RECURRENCE-ID names which instance of a recurrence this component
  # overrides. One that is not a readable date-time overrides nothing,
  # and leaves the recurrence set with a member no client can place.
  defp readable?(%{name: "RECURRENCE-ID", value: value}) do
    match?({:ok, _moment}, Tempo.from_iso8601(value))
  rescue
    _unreadable -> false
  end

  defp recurrence?(value) do
    match?({:ok, _rule}, RRule.parse(value))
  rescue
    _unreadable -> false
  end

  # RFC 4791 section 4.1 wants a VTIMEZONE for each referenced TZID.
  # RFC 7809 — CalDAV Time Zones by Reference — then allowed a client
  # to name a well-known zone and omit the definition, and real clients
  # do. Both are satisfied by asking whether the zone can be resolved:
  # a definition is required only for a name the server cannot look up.
  #
  # This is why `tz` is a dependency. Without a zone database every
  # name looks unknown, and the check either refuses valid data or,
  # dropped entirely, lets a typo through as a reference — a `DTSTART`
  # nobody can place on a timeline.
  defp timezones_present(calendar) do
    defined =
      for component <- calendar.components,
          component.name == "VTIMEZONE",
          property <- component.properties,
          property.name == "TZID",
          into: MapSet.new(),
          do: property.value

    unresolvable =
      for component <- every_component(calendar),
          property <- component.properties,
          zone = Map.get(property.parameters, "TZID"),
          not is_nil(zone),
          not MapSet.member?(defined, zone),
          not known?(zone),
          do: zone

    if unresolvable == [], do: :ok, else: {:error, precondition("valid-calendar-data")}
  end

  defp known?(zone) do
    match?({:ok, _moment}, DateTime.now(zone))
  rescue
    _no_database -> true
  end

  # RFC 4791 section 5.2.9 caps attendees per instance. The limit is
  # the server's to choose; naming one at all is what lets a client be
  # told why a 500-attendee invitation was refused.
  defp within_limits(calendar) do
    too_many? =
      calendar.components
      |> Enum.any?(fn component ->
        Enum.count(component.properties, &(&1.name == "ATTENDEE")) > @max_attendees
      end)

    if too_many?,
      do: {:error, precondition("max-attendees-per-instance")},
      else: :ok
  end

  defp every_component(component) do
    [component | Enum.flat_map(component.components, &every_component/1)]
  end

  # One kind of component, no METHOD, at least one component that can
  # carry a UID.
  defp structure(calendar) do
    kinds =
      calendar.components
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 == "VTIMEZONE"))
      |> Enum.uniq()

    cond do
      method?(calendar) -> {:error, precondition("valid-calendar-object-resource")}
      kinds == [] -> {:error, precondition("valid-calendar-object-resource")}
      length(kinds) > 1 -> {:error, precondition("valid-calendar-object-resource")}
      hd(kinds) not in @scheduling -> {:error, precondition("supported-calendar-component")}
      true -> :ok
    end
  end

  defp method?(calendar), do: Enum.any?(calendar.properties, &(&1.name == "METHOD"))

  # "Calendar components in a calendar collection that have different
  # UID property values MUST be stored in separate calendar object
  # resources."
  defp unique_uid(calendar) do
    case uids(calendar) do
      [_single] -> :ok
      _none_or_several -> {:error, precondition("valid-calendar-object-resource")}
    end
  end

  defp uids(calendar) do
    for component <- calendar.components,
        component.name != "VTIMEZONE",
        property <- component.properties,
        property.name == "UID",
        uniq: true,
        do: property.value
  end

  # RFC 6638 section 3.2.2: the organiser of an event does not change.
  # Whoever is named holds the master copy and every reply is directed
  # at them, so rewriting the name on one copy would send this
  # attendee's answers to somebody who never invited them — and let
  # anyone who was invited take the meeting over.
  defp same_organizer(calendar, path, options) do
    {organizer, _parameters} = organizer_of(calendar)

    cond do
      # Naming nobody is not naming somebody else. A body with no
      # organiser is a different kind of mistake, and the rule about
      # unique scheduling objects has the better name for it.
      is_nil(organizer) -> :ok
      stored_organizer(path, options) == nil -> :ok
      same_person?(stored_organizer(path, options), organizer, options) -> :ok
      true -> {:error, precondition("valid-organizer")}
    end
  end

  # Compared as people, not as strings. The server rewrites an address
  # into the form it considers canonical, so the copy it stored spells
  # the organiser differently from the copy a client sends back — and
  # comparing the spellings makes every ordinary write look like a
  # takeover.
  defp same_person?(one, other, options) do
    one == other or
      (not is_nil(one) and not is_nil(other) and home_of(one, options) == home_of(other, options) and
         home_of(one, options) != nil)
  end

  defp home_of(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{path: path}} <- store.principal(address, context) do
      path
    else
      _unknown -> nil
    end
  end

  defp stored_organizer(path, options) do
    case read_calendar_at(path, options) do
      {:ok, stored} -> stored |> organizer_of() |> elem(0)
      _absent -> nil
    end
  end

  defp read_calendar_at(path, %{store: store, context: context} = options) do
    case store.resolve(path, context) do
      {:ok, existing} -> read_calendar(existing, options)
      _absent -> :error
    end
  end

  # RFC 6638 section 3.2.2: only the organiser creates a scheduling
  # object, or the server does on their behalf when it delivers the
  # invitation. An attendee writing a *new* one into their own
  # calendar would invent a meeting nobody called, and the organiser
  # named on it would never hear of it. Updating the copy they were
  # sent is how they accept, so only a create is refused.
  defp attendee_allowed(calendar, collection, path, options) do
    addresses = Scheduling.addresses_of(collection, options)
    {organizer, parameters} = organizer_of(calendar)

    cond do
      addresses == [] -> :ok
      exists?(path, options) -> :ok
      # A move is not a creation. The invitation already exists — it
      # is being carried from one of the attendee's calendars to
      # another — and refusing it here would trap every delivered
      # event in the calendar it happened to arrive in.
      Map.has_key?(options, :ignoring) -> :ok
      organizer in [nil | addresses] -> :ok
      # The server only owns the scheduling it performs. An organiser
      # this server does not host is somebody else's to police, and a
      # client that has said it will do its own scheduling has taken
      # the job back — refusing either would break iMIP and every
      # `SCHEDULE-AGENT` other than `SERVER`.
      Map.get(parameters, "SCHEDULE-AGENT", "SERVER") != "SERVER" -> :ok
      not Scheduling.hosted?(organizer, options) -> :ok
      # The precondition is about what an *attendee* may do. Someone
      # not named on the event is not one, and the suite expects their
      # write to succeed — an organiser rewriting their own event with
      # no attendees on it yet is the case that shows the difference.
      not attends?(calendar, addresses) -> :ok
      true -> {:error, precondition("attendee-allowed")}
    end
  end

  # RFC 6638 section 3.2.1. An override answers to a series: it names
  # the instance it replaces with `RECURRENCE-ID`, and without a
  # master component there is no series for it to belong to. The
  # organiser is the only one who could have created such a thing, and
  # what they have written is an event that describes an exception to
  # nothing. An attendee's copy is different — the server delivers
  # single instances to people invited to one Tuesday and not the
  # series — so only the organiser's own copy is refused.
  defp organizer_allowed(calendar, collection, options) do
    addresses = Scheduling.addresses_of(collection, options)
    {organizer, _parameters} = organizer_of(calendar)

    if organizer in addresses and orphaned?(calendar),
      do: {:error, precondition("organizer-allowed")},
      else: :ok
  end

  # RFC 6638 section 3.2.2: an attendee's copy is theirs to answer in,
  # not to re-address. `SCHEDULE-AGENT` on the `ORGANIZER` says who
  # delivers for the whole object, so an attendee able to change it
  # could switch the organiser's scheduling on or off from the far
  # side of an invitation they were merely sent.
  defp agent_unchanged(calendar, collection, path, options) do
    {organizer, parameters} = organizer_of(calendar)

    with false <- is_nil(organizer),
         false <- organizer in Scheduling.addresses_of(collection, options),
         # Only for an organiser this server schedules for. One
         # somewhere else is nobody's here to police, and the
         # parameter is then the client's own record of who it
         # expects to deliver.
         true <- Scheduling.hosted?(organizer, options),
         %{} = before <- stored(path, options),
         {^organizer, held} <- organizer_of(before),
         # A `SCHEDULE-AGENT` the *server* wrote is not the client's
         # to be held to: it is stamped alongside a `SCHEDULE-STATUS`
         # saying why, and a client that never sent it cannot be
         # accused of changing it.
         false <- Map.has_key?(held, "SCHEDULE-STATUS"),
         true <- agent_of(held) != agent_of(parameters) do
      {:error, precondition("attendee-allowed")}
    else
      _theirs_or_unchanged -> :ok
    end
  end

  defp agent_of(parameters), do: Map.get(parameters, "SCHEDULE-AGENT", "SERVER")

  defp stored(path, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, resource} <- store.resolve(path, context),
         {:ok, data} <- store.read(resource, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(data)) do
      calendar
    else
      _no_previous_copy -> nil
    end
  end

  defp orphaned?(calendar) do
    case Enum.filter(calendar.components, &(&1.name in ~w(VEVENT VTODO VPOLL))) do
      [] -> false
      scheduled -> Enum.all?(scheduled, &override?/1)
    end
  end

  defp override?(component) do
    Enum.any?(component.properties, &(&1.name == "RECURRENCE-ID"))
  end

  defp attends?(calendar, addresses) do
    Enum.any?(properties_of(calendar), &(&1.name == "ATTENDEE" and &1.value in addresses))
  end

  defp organizer_of(calendar) do
    case Enum.find(properties_of(calendar), &(&1.name == "ORGANIZER")) do
      nil -> {nil, %{}}
      property -> {property.value, property.parameters}
    end
  end

  defp properties_of(calendar) do
    for component <- calendar.components, property <- component.properties, do: property
  end

  defp exists?(path, %{store: store, context: context}) do
    match?({:ok, _resource}, store.resolve(path, context))
  end

  # "MUST NOT specify an iCalendar UID property value already in use in
  # the targeted calendar collection" — except in the resource being
  # replaced, which is an update rather than a conflict.
  defp no_uid_conflict(_calendar, nil, _path, _options), do: :ok

  defp no_uid_conflict(calendar, collection, path, options) do
    [uid] = uids(calendar)

    cond do
      replaced?(uid, path, options) ->
        {:error, precondition("no-uid-conflict")}

      collection |> siblings(path, options) |> Enum.any?(&(uid in uids_of(&1, options))) ->
        {:error, precondition("no-uid-conflict")}

      elsewhere?(uid, collection, path, scheduling?(calendar), options) ->
        {:error, precondition("unique-scheduling-object-resource")}

      true ->
        :ok
    end
  end

  # RFC 6638 section 3.1 narrows `no-uid-conflict` for one class of
  # resource. A *scheduling* object — one carrying an `ORGANIZER` —
  # must be unique across the whole calendar home, not merely within
  # the collection it is written to: two calendars each holding a copy
  # of the same meeting would each answer for it, and a reply could
  # then be applied to either.
  defp scheduling?(calendar) do
    Enum.any?(properties_of(calendar), &(&1.name == "ORGANIZER"))
  end

  # The home's *other* calendar collections. The inbox and outbox are
  # excluded by asking for calendars only: their whole purpose is to
  # hold a copy of a message that already lives in one, so counting
  # them would refuse every invitation the server itself delivered.
  # Either side makes the UID reserved. The rule is about the meeting,
  # not about the document being written: an event carrying no
  # organiser still cannot take a UID that an invitation elsewhere in
  # the home is already using, or a reply would have two resources to
  # choose between.
  defp elsewhere?(uid, collection, path, scheduling?, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :read),
         {:ok, home} <- store.resolve(Enum.drop(collection.path, -1), context),
         {:ok, children} <- store.children(home, context) do
      children
      |> Enum.filter(&(&1.collection? and &1.path != collection.path and Cal.calendar?(&1)))
      |> Enum.flat_map(&siblings(&1, path, options))
      |> Enum.any?(&claims?(&1, uid, scheduling?, options))
    else
      _unreadable -> false
    end
  end

  defp claims?(object, uid, scheduling?, options) do
    case read_calendar(object, options) do
      {:ok, calendar} -> uid in uids(calendar) and (scheduling? or scheduling?(calendar))
      _unreadable -> false
    end
  end

  defp read_calendar(object, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(object, context) do
      ICalendar.parse(IO.iodata_to_binary(data))
    else
      _unreadable -> :error
    end
  end

  # Overwriting a resource with a *different* UID is not an update, it
  # is a different event wearing the same URL. The recurrence set the
  # old UID belonged to would lose a member without anything saying so,
  # so the client is told to write it somewhere else.
  defp replaced?(uid, path, %{store: store, context: context} = options) do
    case store.resolve(path, context) do
      {:ok, existing} -> uids_of(existing, options) not in [[], [uid]]
      _absent -> false
    end
  end

  # The resource being written never conflicts with itself, and neither
  # does one that is about to be moved away.
  defp siblings(collection, path, %{store: store, context: context} = options) do
    ignoring = [path, Map.get(options, :ignoring)]

    case store.children(collection, context) do
      {:ok, children} -> Enum.reject(children, &(&1.collection? or &1.path in ignoring))
      _nothing -> []
    end
  end

  defp uids_of(object, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(object, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(data)) do
      uids(calendar)
    else
      _unreadable -> []
    end
  end

  @doc """
  Whether this validator applies — only inside a calendar collection.

  An ordinary WebDAV collection may hold anything, and applying
  CalDAV's restrictions to it would refuse writes the specification
  permits.

  ### Arguments

  * `collection` is the parent collection, or `nil`.

  ### Returns

  * `true` for a calendar collection.

  ### Examples

      iex> Dav.Cal.Object.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.Object.applies?(%Dav.Web.Resource{collection?: true})
      false

      iex> Dav.Cal.Object.applies?(nil)
      false

  """
  @impl Dav.Web.Validator
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  Whether a collection may be created inside this one.

  ### Arguments

  * `collection` is the parent collection.

  ### Returns

  * `{:error, precondition}` inside a calendar collection, which may
    hold calendar object resources and nothing else; `:ok` otherwise.

  ### Examples

      iex> Dav.Cal.Object.permit_collection(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      {:error, {"urn:ietf:params:xml:ns:caldav", "calendar-collection-location-ok"}}

      iex> Dav.Cal.Object.permit_collection(%Dav.Web.Resource{collection?: true})
      :ok

  """
  @impl Dav.Web.Validator
  @spec permit_collection(Resource.t() | nil) :: :ok | {:error, violation()}
  def permit_collection(collection) do
    if applies?(collection),
      do: {:error, precondition("calendar-collection-location-ok")},
      else: :ok
  end

  defp precondition(name), do: {Xml.caldav(), name}
end
