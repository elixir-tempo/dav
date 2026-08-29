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
    with :ok <- media_type(options),
         :ok <- printable(body),
         {:ok, calendar} <- parse(body),
         :ok <- structure(calendar),
         :ok <- readable_values(calendar),
         :ok <- timezones_present(calendar),
         :ok <- within_limits(calendar),
         :ok <- unique_uid(calendar) do
      no_uid_conflict(calendar, collection, path, options)
    end
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

      true ->
        :ok
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
