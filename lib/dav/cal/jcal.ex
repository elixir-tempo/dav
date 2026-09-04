defmodule Dav.Cal.JCal do
  @moduledoc """
  jCal — RFC 7265, iCalendar written as JSON.

  Not a different calendar model: the same components, the same
  properties, the same parameters, in a syntax a client already has a
  parser for. RFC 7265 is a *mapping*, and its whole value is that it
  is lossless in both directions — which is why this module converts
  to and from `Dav.Cal.ICalendar`'s component structure rather than
  parsing JSON into a model of its own. The server stores iCalendar; a
  client that speaks jCal is answered in jCal, and nothing in between
  knows the difference.

  (Not to be confused with JSCalendar, RFC 8984, which *is* a
  different model — named object fields rather than a transcription of
  iCalendar's content lines.)

  ### The shape

  A component is a three-element array: its name, its properties, its
  sub-components.

      ["vcalendar", [properties…], [components…]]

  A property is `[name, parameters, type, value…]` — the type named
  explicitly, which is the one thing iCalendar leaves implicit:

      ["dtstart", {"tzid":"US/Eastern"}, "date-time", "2026-01-01T10:00:00"]

  Names are lowercased, `VALUE` disappears into the type, and values
  are written in the type's own JSON form: a `date-time` in RFC 3339
  punctuation, a `recur` as an object, an `integer` as a number.

  ### Where the type comes from

  RFC 5545 gives each property a default value type and lets `VALUE`
  override it. A property this module does not recognise gets the type
  `unknown` and travels as a string — RFC 7265 section 3.4.1 provides
  for exactly that, which is what keeps an `X-` property nobody has
  ever seen from being a parse failure.

  ### One limitation, stated

  A comma-separated `TEXT` property — `CATEGORIES:one,two` — becomes a
  single jCal value rather than two. `Dav.Cal.ICalendar` unescapes text
  as it parses, so by the time a value reaches here an escaped `\\,`
  and a separating `,` are the same character and no split can tell
  them apart. Splitting would break `CATEGORIES:Lunch\\, then coffee`,
  which is the worse failure of the two, and the round trip back to
  iCalendar is unaffected either way.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @content_type "application/calendar+json"
  @calendar_type "text/calendar; charset=utf-8"
  @timezone {"urn:ietf:params:xml:ns:caldav", "calendar-timezone"}

  # RFC 5545 section 3.8, plus RFC 7986's additions. A property absent
  # here is `unknown`, not an error.
  @types %{
    "ACTION" => "text",
    "ATTACH" => "uri",
    "ATTENDEE" => "cal-address",
    "BUSYTYPE" => "text",
    "CALSCALE" => "text",
    "CATEGORIES" => "text",
    "CLASS" => "text",
    "COLOR" => "text",
    "COMMENT" => "text",
    "COMPLETED" => "date-time",
    "CONFERENCE" => "uri",
    "CONTACT" => "text",
    "CREATED" => "date-time",
    "DESCRIPTION" => "text",
    "DTEND" => "date-time",
    "DTSTAMP" => "date-time",
    "DTSTART" => "date-time",
    "DUE" => "date-time",
    "DURATION" => "duration",
    "EXDATE" => "date-time",
    "EXRULE" => "recur",
    "FREEBUSY" => "period",
    "GEO" => "float",
    "IMAGE" => "uri",
    "LAST-MODIFIED" => "date-time",
    "LOCATION" => "text",
    "METHOD" => "text",
    "NAME" => "text",
    "ORGANIZER" => "cal-address",
    "PERCENT-COMPLETE" => "integer",
    "PRIORITY" => "integer",
    "PRODID" => "text",
    "RDATE" => "date-time",
    "RECURRENCE-ID" => "date-time",
    "REFRESH-INTERVAL" => "duration",
    "RELATED-TO" => "text",
    "REPEAT" => "integer",
    "REQUEST-STATUS" => "text",
    "RESOURCES" => "text",
    "RRULE" => "recur",
    "SEQUENCE" => "integer",
    "SOURCE" => "uri",
    "STATUS" => "text",
    "SUMMARY" => "text",
    "TRANSP" => "text",
    "TRIGGER" => "duration",
    "TZID" => "text",
    "TZNAME" => "text",
    "TZOFFSETFROM" => "utc-offset",
    "TZOFFSETTO" => "utc-offset",
    "TZURL" => "uri",
    "UID" => "text",
    "URL" => "uri",
    "VERSION" => "text"
  }

  # RFC 5545 section 3.2: the parameters whose value is a
  # comma-separated list, and which RFC 7265 section 3.5.1 therefore
  # writes as an array.
  @list_parameters ~w(DELEGATED-FROM DELEGATED-TO MEMBER)

  # Values that may legitimately hold several, where the separating
  # comma survives parsing. `TEXT` properties are excluded on purpose
  # — see the module note.
  @list_valued ~w(EXDATE RDATE FREEBUSY)

  # RFC 5545 section 3.3.10's ABNF order. A rule written back in this
  # order is byte-identical to one a conformant writer produced, which
  # matters because a `recur` is compared as a string once it is
  # iCalendar again.
  @recur_order ~w(FREQ UNTIL COUNT INTERVAL BYSECOND BYMINUTE BYHOUR BYDAY
                  BYMONTHDAY BYYEARDAY BYWEEKNO BYMONTH BYSETPOS WKST)

  # The recurrence parts holding lists of numbers, as against `BYDAY`'s
  # `-1SU` strings and the scalars.
  @recur_numbers ~w(BYSECOND BYMINUTE BYHOUR BYMONTHDAY BYYEARDAY BYWEEKNO BYMONTH BYSETPOS)

  @doc """
  The media type jCal travels as.

  ### Returns

  * `"application/calendar+json"`.

  ### Examples

      iex> Dav.Cal.JCal.content_type()
      "application/calendar+json"

  """
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc """
  Whether a media type names jCal.

  Compared on the type alone, so the `charset` a client attaches makes
  no difference to what the body is.

  ### Arguments

  * `type` is a media type, with or without parameters. `nil` names
    nothing.

  ### Returns

  * `true` when it is `application/calendar+json`.

  ### Examples

      iex> Dav.Cal.JCal.jcal?("application/calendar+json; charset=utf-8")
      true

      iex> Dav.Cal.JCal.jcal?("text/calendar")
      false

      iex> Dav.Cal.JCal.jcal?(nil)
      false

  """
  @spec jcal?(String.t() | nil) :: boolean()
  def jcal?(type) when is_binary(type) do
    type |> String.split(";") |> List.first() |> String.trim() |> String.downcase() ==
      @content_type
  end

  def jcal?(_absent), do: false

  @doc """
  Write a component as jCal.

  ### Arguments

  * `component` is a `t:Dav.Cal.ICalendar.component/0`.

  ### Returns

  * The jCal document as a binary.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nVERSION:2.0\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> Dav.Cal.JCal.encode(calendar)
      ~s([\"vcalendar\",[[\"version\",{},\"text\",\"2.0\"]],[]])

  """
  @spec encode(ICalendar.component()) :: binary()
  def encode(component) do
    component |> component_out() |> :json.encode() |> IO.iodata_to_binary()
  end

  defp component_out(component) do
    [
      String.downcase(component.name),
      Enum.map(component.properties, &stated/1),
      Enum.map(component.components, &component_out/1)
    ]
  end

  defp stated(property) do
    type = type_of(property)

    [String.downcase(property.name), attributed(property), type | values(property, type)]
  end

  # `VALUE` is not a parameter in jCal — it *is* the third element, so
  # carrying it as well would state the type twice and let the two
  # disagree.
  defp attributed(property) do
    for {name, value} <- property.parameters, name != "VALUE", into: %{} do
      {String.downcase(name), listed(name, value)}
    end
  end

  defp listed(name, value) when name in @list_parameters, do: String.split(value, ",")
  defp listed(_name, value), do: value

  defp type_of(%{parameters: %{"VALUE" => named}}) when is_binary(named) and named != "",
    do: String.downcase(named)

  defp type_of(%{name: name}), do: Map.get(@types, name, "unknown")

  defp values(property, type) do
    property
    |> parts()
    |> Enum.map(&value_out(&1, type))
  end

  defp parts(%{name: name, value: value}) when name in @list_valued, do: String.split(value, ",")
  defp parts(%{value: value}), do: [value]

  ## --- values, iCalendar to JSON -----------------------------------

  defp value_out(value, "date-time"), do: stamped(value)
  defp value_out(value, "date"), do: dated(value)
  defp value_out(value, "time"), do: clocked(value)
  defp value_out(value, "utc-offset"), do: offset_out(value)
  defp value_out(value, "period"), do: period_out(value)
  defp value_out(value, "recur"), do: recur_out(value)
  defp value_out(value, "boolean"), do: String.upcase(value) == "TRUE"
  defp value_out(value, type) when type in ["integer", "float"], do: numbered(value)
  defp value_out(value, _text_or_unknown), do: value

  # `20260101T100000Z` is `2026-01-01T10:00:00Z`. A value that is not
  # a timestamp at all is left as written: RFC 7265 has no repair
  # rules, and mangling it would hide the client's mistake rather than
  # carry it.
  defp stamped(<<y::binary-4, m::binary-2, d::binary-2, "T", rest::binary>> = value) do
    case rest do
      <<hh::binary-2, mm::binary-2, ss::binary-2, zone::binary>> when zone in ["", "Z"] ->
        "#{y}-#{m}-#{d}T#{hh}:#{mm}:#{ss}#{zone}"

      _not_a_time ->
        value
    end
  end

  defp stamped(value), do: dated(value)

  defp dated(<<y::binary-4, m::binary-2, d::binary-2>>), do: "#{y}-#{m}-#{d}"
  defp dated(value), do: value

  defp clocked(<<hh::binary-2, mm::binary-2, ss::binary-2, zone::binary>>)
       when zone in ["", "Z"],
       do: "#{hh}:#{mm}:#{ss}#{zone}"

  defp clocked(value), do: value

  # `-0500` is `-05:00`, and the seconds RFC 5545 allows travel too.
  defp offset_out(<<sign::binary-1, hh::binary-2, mm::binary-2>>) when sign in ["+", "-"],
    do: "#{sign}#{hh}:#{mm}"

  defp offset_out(<<sign::binary-1, hh::binary-2, mm::binary-2, ss::binary-2>>)
       when sign in ["+", "-"],
       do: "#{sign}#{hh}:#{mm}:#{ss}"

  defp offset_out(value), do: value

  # A period is two moments, or a moment and a duration — an array of
  # two either way, because the second element says which it is by its
  # own spelling.
  defp period_out(value) do
    case String.split(value, "/", parts: 2) do
      [start, rest] -> [stamped(start), boundary_out(rest)]
      [only] -> [stamped(only)]
    end
  end

  defp boundary_out("P" <> _rest = duration), do: duration
  defp boundary_out("-P" <> _rest = duration), do: duration
  defp boundary_out(moment), do: stamped(moment)

  defp recur_out(value) do
    for part <- String.split(value, ";"), part != "", into: %{} do
      {name, stated} =
        case String.split(part, "=", parts: 2) do
          [name, stated] -> {String.upcase(name), stated}
          [name] -> {String.upcase(name), ""}
        end

      {String.downcase(name), recur_part_out(name, stated)}
    end
  end

  defp recur_part_out(name, value) when name in @recur_numbers,
    do: value |> String.split(",") |> Enum.map(&numbered/1)

  defp recur_part_out("BYDAY", value), do: String.split(value, ",")
  defp recur_part_out(name, value) when name in ["COUNT", "INTERVAL"], do: numbered(value)
  defp recur_part_out("UNTIL", value), do: stamped(value)
  defp recur_part_out(_name, value), do: value

  # A number that is not one stays a string. jCal has no way to write
  # a malformed integer as an integer, and a client that sent
  # `PRIORITY:high` is owed its own value back rather than a zero.
  defp numbered(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_an_integer -> floated(value)
    end
  end

  defp floated(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_a_number -> value
    end
  end

  @doc """
  Read a jCal document as a component.

  ### Arguments

  * `body` is the jCal document.

  ### Returns

  * `{:ok, component}` as `Dav.Cal.ICalendar` would have parsed the
    equivalent iCalendar; or

  * `{:error, :malformed}` when the body is not JSON, or is JSON that
    is not a jCal component.

  ### Examples

      iex> Dav.Cal.JCal.decode(~s([\"vcalendar\",[[\"version\",{},\"text\",\"2.0\"]],[]]))
      {:ok, %{name: "VCALENDAR", properties: [%{name: "VERSION", parameters: %{}, value: "2.0"}], components: []}}

      iex> Dav.Cal.JCal.decode("{}")
      {:error, :malformed}

      iex> Dav.Cal.JCal.decode("not json")
      {:error, :malformed}

  """
  @spec decode(binary()) :: {:ok, ICalendar.component()} | {:error, :malformed}
  def decode(body) when is_binary(body) do
    case read(body) do
      {:ok, document} -> component(document)
      failure -> failure
    end
  end

  # `:json.decode/1` raises on a malformed document and offers no
  # tuple-returning form, which is the one place a rescue is the
  # interface rather than control flow.
  defp read(body) do
    {:ok, :json.decode(body)}
  rescue
    _malformed -> {:error, :malformed}
  end

  defp component([name, properties, components])
       when is_binary(name) and is_list(properties) and is_list(components) do
    with {:ok, held} <- collect(properties, &property/1),
         {:ok, nested} <- collect(components, &component/1) do
      {:ok, %{name: String.upcase(name), properties: held, components: nested}}
    end
  end

  defp component(_not_a_component), do: {:error, :malformed}

  defp collect(items, reader) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, seen} ->
      case reader.(item) do
        {:ok, read} -> {:cont, {:ok, seen ++ [read]}}
        failure -> {:halt, failure}
      end
    end)
  end

  defp property([name, parameters, type | values])
       when is_binary(name) and is_map(parameters) and is_binary(type) do
    {:ok,
     %{
       name: String.upcase(name),
       parameters: parameters_in(parameters, name, type),
       value: Enum.map_join(values, ",", &value_in(&1, type))
     }}
  end

  defp property(_not_a_property), do: {:error, :malformed}

  # The type comes back as a `VALUE` parameter only where iCalendar
  # would have carried one: a property written in its own default type
  # needs no parameter, and adding one to every line would change every
  # document that round-trips through here.
  defp parameters_in(parameters, name, type) do
    stated =
      for {parameter, value} <- parameters, into: %{} do
        {String.upcase(parameter), unlisted(value)}
      end

    if default?(name, type), do: stated, else: Map.put(stated, "VALUE", String.upcase(type))
  end

  defp default?(name, type) do
    String.downcase(type) == Map.get(@types, String.upcase(name), "unknown")
  end

  defp unlisted(value) when is_list(value), do: Enum.join(value, ",")
  defp unlisted(value) when is_binary(value), do: value
  defp unlisted(value), do: to_string(value)

  ## --- values, JSON to iCalendar -----------------------------------

  defp value_in(value, "date-time"), do: unstamped(value)
  defp value_in(value, "date"), do: undated(value)
  defp value_in(value, "time"), do: unclocked(value)
  defp value_in(value, "utc-offset"), do: offset_in(value)
  defp value_in(value, "period"), do: period_in(value)
  defp value_in(value, "recur"), do: recur_in(value)
  defp value_in(true, "boolean"), do: "TRUE"
  defp value_in(false, "boolean"), do: "FALSE"
  defp value_in(value, _other), do: written_value(value)

  defp written_value(value) when is_binary(value), do: value
  defp written_value(value) when is_integer(value), do: Integer.to_string(value)
  defp written_value(value) when is_float(value), do: Float.to_string(value)
  defp written_value(true), do: "TRUE"
  defp written_value(false), do: "FALSE"
  defp written_value(value), do: to_string(value)

  defp unstamped(<<y::binary-4, "-", m::binary-2, "-", d::binary-2, "T", rest::binary>> = value) do
    case rest do
      <<hh::binary-2, ":", mm::binary-2, ":", ss::binary-2, zone::binary>>
      when zone in ["", "Z"] ->
        "#{y}#{m}#{d}T#{hh}#{mm}#{ss}#{zone}"

      _not_a_time ->
        value
    end
  end

  defp unstamped(value), do: undated(value)

  defp undated(<<y::binary-4, "-", m::binary-2, "-", d::binary-2>>), do: "#{y}#{m}#{d}"
  defp undated(value), do: written_value(value)

  defp unclocked(<<hh::binary-2, ":", mm::binary-2, ":", ss::binary-2, zone::binary>>)
       when zone in ["", "Z"],
       do: "#{hh}#{mm}#{ss}#{zone}"

  defp unclocked(value), do: written_value(value)

  defp offset_in(<<sign::binary-1, hh::binary-2, ":", mm::binary-2>>) when sign in ["+", "-"],
    do: "#{sign}#{hh}#{mm}"

  defp offset_in(<<sign::binary-1, hh::binary-2, ":", mm::binary-2, ":", ss::binary-2>>)
       when sign in ["+", "-"],
       do: "#{sign}#{hh}#{mm}#{ss}"

  defp offset_in(value), do: written_value(value)

  defp period_in([start, boundary]), do: "#{unstamped(start)}/#{boundary_in(boundary)}"
  defp period_in([only]), do: unstamped(only)
  defp period_in(value), do: written_value(value)

  defp boundary_in("P" <> _rest = duration), do: duration
  defp boundary_in("-P" <> _rest = duration), do: duration
  defp boundary_in(moment), do: unstamped(moment)

  # Written back in RFC 5545's own order rather than the object's,
  # which has none: a JSON object is unordered, and a rule reassembled
  # in whatever order the parser happened to hand over would differ
  # from the same rule written by anybody else.
  defp recur_in(parts) when is_map(parts) do
    named = for {name, value} <- parts, into: %{}, do: {String.upcase(name), value}
    known = @recur_order ++ (named |> Map.keys() |> Enum.sort())

    known
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(named, &1))
    |> Enum.map_join(";", &"#{&1}=#{recur_part_in(&1, Map.fetch!(named, &1))}")
  end

  defp recur_in(value), do: written_value(value)

  defp recur_part_in("UNTIL", value), do: unstamped(value)

  defp recur_part_in(_name, value) when is_list(value),
    do: Enum.map_join(value, ",", &written_value/1)

  defp recur_part_in(_name, value), do: written_value(value)

  ## --- where this server speaks it ---------------------------------

  @doc """
  jCal is a calendar's second syntax, and applies where calendars are.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for a calendar.

  ### Examples

      iex> Dav.Cal.JCal.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.JCal.applies?(nil)
      false

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  A write changes nothing here — this hook only translates.

  ### Arguments

  * `change` is the write, unused.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`.

  ### Examples

      iex> Dav.Cal.JCal.written(%{}, %{})
      :ok

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  Take a jCal body as the iCalendar the store keeps.

  Converting on the way in rather than storing both syntaxes is the
  whole point: one representation is stored, so a `UID` conflict, a
  scheduling message and a free-busy answer are all computed from the
  same bytes no matter which syntax the client happened to write.

  ### Arguments

  * `collection` is the collection being written into.

  * `body` is the request body.

  * `content_type` is the media type the client stated.

  * `options` carries the request context, unused.

  ### Returns

  * `{:ok, body, "text/calendar; charset=utf-8"}` for a jCal body in a
    calendar, or `:skip` for anything else — a body that says it is
    jCal and is not travels on unconverted, so it is refused by the
    validator that reads calendar data rather than here.

  ### Examples

      iex> calendar = %Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]}
      iex> {:ok, body, type} = Dav.Cal.JCal.taken(calendar, ~s([\"vcalendar\",[],[]]), "application/calendar+json", %{})
      iex> {body, type}
      {"BEGIN:VCALENDAR\\r\\nEND:VCALENDAR\\r\\n", "text/calendar; charset=utf-8"}

      iex> Dav.Cal.JCal.taken(nil, "BEGIN:VCALENDAR\\r\\nEND:VCALENDAR\\r\\n", "text/calendar", %{})
      :skip

  """
  @impl Dav.Web.Hook
  @spec taken(Resource.t() | nil, binary(), String.t() | nil, map()) ::
          {:ok, binary(), String.t()} | :skip
  def taken(collection, body, content_type, _options) do
    with true <- applies?(collection),
         true <- jcal?(content_type),
         {:ok, component} <- decode(body) do
      {:ok, ICalendar.write(component), @calendar_type}
    else
      _not_jcal_in_a_calendar -> :skip
    end
  end

  @doc """
  Answer a calendar object as jCal when that is what was asked for.

  ### Arguments

  * `resource` is the resource being read, unused.

  * `collection` is the collection holding it.

  * `body` is the stored iCalendar.

  * `content_type` is the media type it is held as.

  * `accept` is the request's `Accept` header values.

  * `options` carries the request context, unused.

  ### Returns

  * `{:ok, "application/calendar+json", body}` when the client asked
    for jCal and the object is calendar data, or `:skip`.

  ### Examples

      iex> calendar = %Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]}
      iex> object = %Dav.Web.Resource{path: ["c", "1.ics"]}
      iex> Dav.Cal.JCal.offered(object, calendar, "BEGIN:VCALENDAR\\r\\nEND:VCALENDAR\\r\\n", "text/calendar", ["application/calendar+json"], %{})
      {:ok, "application/calendar+json", ~s([\"vcalendar\",[],[]])}

      iex> object = %Dav.Web.Resource{path: ["c", "1.ics"]}
      iex> Dav.Cal.JCal.offered(object, nil, "BEGIN:VCALENDAR\\r\\n", "text/calendar", ["application/calendar+json"], %{})
      :skip

  """
  @impl Dav.Web.Hook
  @spec offered(
          Resource.t(),
          Resource.t() | nil,
          binary(),
          String.t() | nil,
          [String.t()],
          map()
        ) :: {:ok, String.t(), binary()} | :skip
  def offered(_resource, collection, body, content_type, accept, _options) do
    with true <- applies?(collection),
         true <- calendar_type?(content_type),
         true <- preferred?(accept),
         {:ok, component} <- ICalendar.parse(body) do
      {:ok, @content_type, encode(component)}
    else
      _not_asked_for -> :skip
    end
  end

  @doc """
  Store a `CALDAV:calendar-timezone` written as jCal as iCalendar.

  The property is not decoration: `Dav.Cal.Query` resolves a floating
  time against it, and `Dav.Cal.Object` validates against it. Storing
  the client's JSON would leave both reading a syntax they do not
  parse, so the conversion happens as the instruction is judged and
  nothing downstream learns that jCal exists.

  ### Arguments

  * `resource` is the resource being patched, unused.

  * `instruction` is one parsed `PROPPATCH` instruction.

  * `options` carries the request context, unused.

  ### Returns

  * `{:ok, instruction}` with the value converted, or `:ok` for
    anything this hook has no opinion about.

  ### Examples

      iex> jcal = ~s([\"vcalendar\",[],[[\"vtimezone\",[[\"tzid\",{},\"text\",\"UTC\"]],[]]]])
      iex> instruction = {:set, {Dav.Xml.caldav(), "calendar-timezone"}, {:typed, "application/calendar+json", jcal}}
      iex> {:ok, {:set, _name, stored}} = Dav.Cal.JCal.patchable(%Dav.Web.Resource{}, instruction, %{})
      iex> stored =~ "BEGIN:VTIMEZONE"
      true

      iex> Dav.Cal.JCal.patchable(%Dav.Web.Resource{}, {:remove, {"DAV:", "displayname"}}, %{})
      :ok

  """
  @impl Dav.Web.Hook
  @spec patchable(Resource.t(), Hook.instruction(), map()) ::
          :ok | {:ok, Hook.instruction()} | {:error, Xml.qname()}
  def patchable(_resource, {:set, name, {:typed, type, text}}, _options) do
    with true <- jcal?(type),
         {:ok, component} <- decode(text) do
      {:ok, {:set, name, ICalendar.write(component)}}
    else
      _not_jcal -> {:ok, {:set, name, text}}
    end
  end

  def patchable(_resource, _instruction, _options), do: :ok

  @doc """
  `CALDAV:calendar-timezone` as jCal, when that is how it was asked for.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it, unused.

  * `options` carries `:asked` — the attributes the client wrote on
    the properties it requested — along with `:store` and `:context`.

  ### Returns

  * The property in jCal, or nothing when the client asked for it in
    iCalendar or did not ask for it at all.

  ### Examples

      iex> Dav.Cal.JCal.properties(%Dav.Web.Resource{}, nil, %{})
      []

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(%Resource{} = resource, _collection, options) do
    with true <- asked_as_jcal?(options),
         held when is_binary(held) <- stored_zone(resource, options),
         {:ok, component} <- ICalendar.parse(held) do
      [{@timezone, {:typed, @content_type, encode(component)}}]
    else
      _not_asked_for_in_json -> []
    end
  end

  defp asked_as_jcal?(options) do
    options
    |> Map.get(:asked, %{})
    |> Map.get(@timezone, %{})
    |> Map.get("content-type")
    |> jcal?()
  end

  defp stored_zone(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = held <- store.properties(resource, context) do
      Map.get(held, @timezone)
    else
      _unstored -> nil
    end
  end

  defp stored_zone(_resource, _options), do: nil

  defp calendar_type?(nil), do: true

  defp calendar_type?(type) do
    type |> String.split(";") |> List.first() |> String.trim() |> String.downcase() ==
      "text/calendar"
  end

  # Which of the two the client would rather have, decided by RFC 9110
  # weights. A header naming both without weights prefers the one
  # written first, which is what a client means by the order it wrote
  # them in; equal weights fall back to that same order.
  defp preferred?(accept) do
    ranked = accept |> Enum.flat_map(&String.split(&1, ",")) |> Enum.map(&String.trim/1)

    case {rank(ranked, @content_type), rank(ranked, "text/calendar")} do
      {nil, _icalendar} ->
        false

      {_jcal, nil} ->
        true

      {{jcal_weight, jcal_at}, {ical_weight, ical_at}} ->
        {-jcal_weight, jcal_at} < {-ical_weight, ical_at}
    end
  end

  # The weight and the position of the first entry naming a type, or
  # `nil` when none does. `*/*` counts for neither: a client that will
  # take anything has expressed no preference between them.
  defp rank(ranked, type) do
    ranked
    |> Enum.with_index()
    |> Enum.find_value(&ranked_as(&1, type))
  end

  defp ranked_as({entry, at}, type) do
    [named | parameters] = String.split(entry, ";")

    if String.trim(named) == type, do: {weight(parameters), at}
  end

  defp weight(parameters) do
    parameters
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(1.0, &stated_weight/1)
  end

  defp stated_weight("q=" <> value) do
    case Float.parse(value) do
      {q, _rest} -> q
      :error -> nil
    end
  end

  defp stated_weight(_not_a_weight), do: nil
end
