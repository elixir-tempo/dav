defmodule Dav.Cal.ICalendar do
  @moduledoc """
  iCalendar read as structure rather than meaning — RFC 5545 section 3.1.

  CalDAV's filter language is generic on purpose: `prop-filter` names
  any property, `param-filter` any parameter, and a client may ask
  about `X-APPLE-TRAVEL-DURATION` as readily as about `SUMMARY`. So
  matching a filter is a *structural* question, and answering it needs
  the content lines as written rather than a domain model of what they
  mean.

  That is why this exists alongside Tempo rather than instead of it.
  `Tempo.ICal.from_ical/2` reads calendar data into intervals with
  named metadata — summary, location, attendees — which is the right
  shape for working with calendars and the wrong one for filtering: a
  property it does not model cannot be named, and a *parameter* such
  as `PARTSTAT` on an `ATTENDEE` does not survive at all. Custom `X-`
  properties are kept, but a filter may name any property, not only
  those two categories.

  The division of labour is **structure here, meaning in Tempo.**
  Matching component and property names, and text within them, needs
  the lines as written. `time-range` needs the opposite — `DTSTART`,
  `DURATION`, and recurrence expanded across `RRULE`, `RDATE` and
  `EXDATE` — and that is Tempo's, through `Tempo.ICal` and
  `Tempo.RRule`. This module deliberately does not interpret a single
  date.

  """

  # RFC 5545 section 3.1: "Lines of text SHOULD NOT be longer than
  # 75 octets, excluding the line break." The reference server folds
  # a character earlier — 74 octets on the first line — and the
  # conformance fixtures compare folded bytes, so this matches it.
  @limit 74

  # Properties whose values are iCalendar TEXT, and so carry escapes.
  # Everything else — RRULE, EXDATE, GEO, FREEBUSY — uses `;` and `,`
  # structurally.
  @text_valued ~w(SUMMARY DESCRIPTION LOCATION COMMENT CONTACT
                  CATEGORIES RESOURCES RELATED-TO TZNAME X-WR-CALNAME
                  X-CALENDARSERVER-PRIVATE-COMMENT X-CALENDARSERVER-ATTENDEE-COMMENT)

  @typedoc "One `NAME;PARAM=value:value` line."
  @type property :: %{
          name: String.t(),
          parameters: %{optional(String.t()) => String.t()},
          value: String.t()
        }

  @typedoc "A `BEGIN:X` … `END:X` block."
  @type component :: %{
          name: String.t(),
          properties: [property()],
          components: [component()]
        }

  @doc """
  Write a component back out as iCalendar.

  The counterpart to `parse/1`, and needed wherever a component is
  rebuilt rather than passed through: a `calendar-data` subset, or a
  scheduling message being stored in an Inbox.

  Values are **re-escaped**. Parsing turns `\\n` into a newline and
  `\\,` into a comma, so writing the parsed value back unchanged
  produces a line that means something different from the one that
  came in — and, in the case of an embedded newline, a line that ends
  the object early.

  ### Arguments

  * `component` is a `t:component/0`.

  ### Returns

  * The component as iCalendar text, folded, with CRLF endings.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> Dav.Cal.ICalendar.write(calendar) == ics
      true

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nSUMMARY:one\\\\ntwo\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> Dav.Cal.ICalendar.write(calendar) =~ "SUMMARY:one\\\\ntwo"
      true

  """
  @spec write(component()) :: binary()
  def write(component) do
    component |> content_lines() |> Enum.map_join("", &(fold(&1) <> "\r\n"))
  end

  defp content_lines(component) do
    ["BEGIN:" <> component.name] ++
      Enum.map(component.properties, &content_line/1) ++
      Enum.flat_map(component.components, &content_lines/1) ++
      ["END:" <> component.name]
  end

  defp content_line(property) do
    parameters =
      Enum.map_join(property.parameters, "", fn {name, value} ->
        ";" <> name <> "=" <> encode_parameter(value)
      end)

    property.name <> parameters <> ":" <> encode(property)
  end

  # Only TEXT values are escaped. `RRULE:FREQ=WEEKLY;BYDAY=MO,TU` uses
  # `;` and `,` as *structure*, and escaping them turns a recurrence
  # rule into one long unparseable string — which is exactly what
  # happened to every VTIMEZONE this rewrote.
  defp encode(%{name: name, value: value}) when name in @text_valued, do: escape(value)
  defp encode(%{value: value}), do: value

  # RFC 5545 section 3.3.11. The backslash goes first: escaping it
  # after the others would double the backslashes they introduced.
  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
  end

  @doc """
  Fold a content line to the 75-octet limit.

  RFC 5545 section 3.1: a line longer than 75 octets is broken with a
  CRLF followed by a single space, which a reader unfolds by removing
  both. The continuation's leading space counts toward its own 75, so
  only the first segment gets the full width.

  Folding happens at a character boundary, never inside a multi-octet
  UTF-8 sequence — the limit counts octets, so a naive split on 75
  bytes corrupts any line with a non-ASCII character near the edge.

  ### Arguments

  * `line` is one unfolded content line, without its terminator.

  ### Returns

  * The line, with CRLF-space inserted where needed.

  ### Examples

      iex> Dav.Cal.ICalendar.fold("SUMMARY:short")
      "SUMMARY:short"

      iex> String.duplicate("a", 200)
      ...> |> Dav.Cal.ICalendar.fold()
      ...> |> String.split("\\r\\n ")
      ...> |> Enum.map(&byte_size/1)
      [74, 73, 53]

  """
  @spec fold(binary()) :: binary()
  def fold(line) when is_binary(line) do
    case take(line, @limit) do
      {head, ""} -> head
      {head, rest} -> IO.iodata_to_binary([head | continuations(rest)])
    end
  end

  defp continuations(""), do: []

  defp continuations(rest) do
    {head, more} = take(rest, @limit - 1)
    ["\r\n ", head | continuations(more)]
  end

  defp take(string, limit), do: take(string, limit, [])

  defp take(string, left, taken) do
    case String.next_grapheme(string) do
      nil ->
        {IO.iodata_to_binary(Enum.reverse(taken)), ""}

      {grapheme, rest} ->
        if byte_size(grapheme) > left do
          {IO.iodata_to_binary(Enum.reverse(taken)), string}
        else
          take(rest, left - byte_size(grapheme), [grapheme | taken])
        end
    end
  end

  @doc """
  Parse an iCalendar object into nested components.

  ### Arguments

  * `data` is the body of a calendar object resource.

  ### Returns

  * `{:ok, component}` for the outermost component, normally
    `VCALENDAR`; or

  * `{:error, :malformed}` when there is no complete component in it.

  ### Examples

      iex> data = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nSUMMARY:Lunch\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(data)
      iex> [event] = calendar.components
      iex> {calendar.name, event.name, hd(event.properties).value}
      {"VCALENDAR", "VEVENT", "Lunch"}

      iex> Dav.Cal.ICalendar.parse("BEGIN:VEVENT")
      {:error, :malformed}

  """
  @spec parse(binary()) :: {:ok, component()} | {:error, :malformed}
  def parse(data) when is_binary(data) do
    data
    |> unfold()
    |> Enum.reduce({[], nil}, &collect/2)
    |> case do
      # Nothing still open, and something closed. An open component
      # looks identical to a finished one unless the two are tracked
      # apart — which is how `BEGIN:VEVENT` alone otherwise parses as
      # a perfectly good component.
      {[], %{} = component} -> {:ok, component}
      _incomplete -> {:error, :malformed}
    end
  end

  # RFC 5545 section 3.1: a line may be broken by CRLF followed by a
  # single space or tab, and the break is not part of the value. Real
  # clients fold aggressively, so this is not an edge case.
  defp unfold(data) do
    data
    |> strip_bom()
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/, trim: true)
  end

  # A UTF-8 byte order mark is legal at the start of a file and carries
  # no meaning in a stream that is already known to be UTF-8. Left in
  # place it becomes part of the first line, so `BEGIN:VCALENDAR` reads
  # as `\uFEFFBEGIN:VCALENDAR` and the whole object parses as empty —
  # which is how a perfectly good calendar gets refused as malformed.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(data), do: data

  defp collect("BEGIN:" <> name, {stack, done}) do
    {[%{name: name, properties: [], components: []} | stack], done}
  end

  defp collect("END:" <> name, {[%{name: name} = closing | [parent | rest]], done}) do
    {[%{parent | components: parent.components ++ [closing]} | rest], done}
  end

  defp collect("END:" <> name, {[%{name: name} = closing], _done}), do: {[], closing}

  defp collect(_line, {[], done}), do: {[], done}

  defp collect(line, {[%{} = current | rest], done}) do
    case property(line) do
      nil -> {[current | rest], done}
      parsed -> {[%{current | properties: current.properties ++ [parsed]} | rest], done}
    end
  end

  # `NAME;PARAM=value;OTHER="quoted:value":the value`. The colon that
  # ends the name and parameters is the first one outside quotes —
  # values routinely contain colons, in a URI or a timezone id.
  defp property(line) do
    case split_on_value(line) do
      {"", _value} -> nil
      {head, value} -> build(head, value)
      :none -> nil
    end
  end

  defp build(head, value) do
    [name | parameters] = split_on_semicolons(head)

    %{
      name: String.upcase(name),
      parameters: Map.new(parameters, &parameter/1),
      value: unescape(value)
    }
  end

  defp parameter(text) do
    case String.split(text, "=", parts: 2) do
      [name, value] -> {String.upcase(name), value |> unquote_value() |> decode_parameter()}
      [name] -> {String.upcase(name), ""}
    end
  end

  # RFC 6868. A parameter value cannot hold a newline, a double quote
  # or a colon, so those are written as `^n`, `^'` and — for a literal
  # circumflex — `^^`. Anything else after a `^` is not an escape and
  # stands as written, which is what lets a value containing one stray
  # `^` survive being read and written again.
  defp decode_parameter(value), do: decode_parameter(value, "")

  defp decode_parameter("", seen), do: seen
  defp decode_parameter("^n" <> rest, seen), do: decode_parameter(rest, seen <> "\n")
  defp decode_parameter("^'" <> rest, seen), do: decode_parameter(rest, seen <> "\"")
  defp decode_parameter("^^" <> rest, seen), do: decode_parameter(rest, seen <> "^")

  defp decode_parameter(<<character::utf8, rest::binary>>, seen),
    do: decode_parameter(rest, seen <> <<character::utf8>>)

  # RFC 5545 section 3.1: a parameter value holding `:`, `;` or `,`
  # must be quoted, or the reader takes the first one as the end of
  # the parameter — an `X-CALENDARSERVER-ATTENDEE-REF=urn:x-uid:…`
  # written bare comes back as the parameter `urn` and a value that
  # was the rest of the address.
  defp encode_parameter(value) do
    escaped =
      value
      |> String.replace("^", "^^")
      |> String.replace("\n", "^n")
      |> String.replace("\"", "^'")

    if String.contains?(escaped, [":", ";", ","]), do: ~s("#{escaped}"), else: escaped
  end

  defp unquote_value(<<?", rest::binary>>) do
    rest |> String.trim_trailing("\"") |> unquote_value()
  end

  defp unquote_value(value), do: value

  defp unescape(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\;", ";")
    |> String.replace("\\\\", "\\")
  end

  defp split_on_value(line), do: scan(line, "", false)

  defp scan("", _acc, _quoted?), do: :none
  defp scan(<<?", rest::binary>>, acc, quoted?), do: scan(rest, acc <> "\"", not quoted?)
  defp scan(<<?:, rest::binary>>, acc, false), do: {acc, rest}

  defp scan(<<char::utf8, rest::binary>>, acc, quoted?),
    do: scan(rest, acc <> <<char::utf8>>, quoted?)

  defp split_on_semicolons(head), do: pieces(head, "", false, [])

  defp pieces("", acc, _quoted?, taken), do: Enum.reverse([acc | taken])

  defp pieces(<<?", rest::binary>>, acc, quoted?, taken),
    do: pieces(rest, acc, not quoted?, taken)

  defp pieces(<<?;, rest::binary>>, acc, false, taken), do: pieces(rest, "", false, [acc | taken])

  defp pieces(<<char::utf8, rest::binary>>, acc, quoted?, taken) do
    pieces(rest, acc <> <<char::utf8>>, quoted?, taken)
  end
end
