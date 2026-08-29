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
  # 75 octets, excluding the line break."
  @limit 75

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
      [75, 74, 51]

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
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/, trim: true)
  end

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
      [name, value] -> {String.upcase(name), unquote_value(value)}
      [name] -> {String.upcase(name), ""}
    end
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
