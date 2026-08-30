defmodule Dav.CalDAVTester.Calendars do
  @moduledoc """
  Comparing two iCalendar objects the way `calendarDataMatch` does.

  A byte comparison is useless here: a server may fold lines
  differently, order properties differently, and must stamp its own
  `DTSTAMP` and `PRODID`. So the comparison is structural — components
  and properties as sets — after filtering out what the suite says to
  ignore.

  ### The filters

  `serverinfo.xml` supplies a standing list, and a test may add more.
  Three forms, all seen in the suite:

  * `DTSTAMP` — drop the property wherever it appears.
  * `ATTENDEE:EMAIL` — drop that *parameter* from that property.
  * `TRANSP=OPAQUE` — drop the property when it carries the default
    value, so a server that writes the default explicitly and one that
    omits it compare equal.

  A leading `!` in a test's filter list removes a standing filter,
  which is how a test says it does care about `DTSTAMP` after all.

  """

  alias Dav.Cal.ICalendar

  # The filters `serverinfo.xml` applies to every comparison. Kept here
  # rather than read from the file because they are the property of the
  # comparison, and a test that adds to them expects these underneath.
  @standing ~w(PRODID CALSCALE DTSTAMP CREATED LAST-MODIFIED X-WR-CALNAME
               ATTENDEE:X-CALENDARSERVER-DTSTAMP ATTENDEE:X-CALENDARSERVER-AUTO
               ATTENDEE:X-CALENDARSERVER-RESET-PARTSTAT ATTENDEE:EMAIL ORGANIZER:EMAIL
               CLASS=PUBLIC PRIORITY=0 TRANSP=OPAQUE SEQUENCE=0)

  @typedoc "The outcome of a comparison."
  @type outcome :: :passed | {:failed, String.t()} | {:skipped, String.t()}

  @doc """
  Compare a response body against expected calendar data.

  ### Arguments

  * `actual` is the response body.

  * `expected` is the fixture or inline data to compare against.

  * `filters` are the test's own filters, added to the standing list.

  ### Returns

  * `:passed`, `{:failed, reason}`, or `{:skipped, reason}` when either
    side is not readable as iCalendar.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nDTSTAMP:20260101T000000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> other = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nDTSTAMP:20991231T235959Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> Dav.CalDAVTester.Calendars.compare(ics, other, [])
      :passed

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> other = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:2\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> match?({:failed, _reason}, Dav.CalDAVTester.Calendars.compare(ics, other, []))
      true

  """
  @spec compare(binary(), binary(), [String.t()]) :: outcome()
  def compare(actual, expected, filters) do
    rules = rules(filters)

    with {:ok, left} <- read(actual),
         {:ok, right} <- read(expected) do
      difference(normalise(left, rules), normalise(right, rules))
    end
  end

  # A response often carries the calendar inside a multistatus rather
  # than alone, so the object is found within whatever came back.
  defp read(body) do
    case ICalendar.parse(body) do
      {:ok, calendar} -> {:ok, calendar}
      _not_alone -> embedded(body)
    end
  end

  defp embedded(body) do
    case Regex.run(~r/BEGIN:VCALENDAR.*?END:VCALENDAR/s, unescape(body)) do
      [found] -> ICalendar.parse(ensure_crlf(found))
      _absent -> {:skipped, "response holds no readable calendar data"}
    end
  end

  defp unescape(body) do
    body
    |> String.replace("&#13;", "\r")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("\r\n ", "")
  end

  defp ensure_crlf(text) do
    text |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n") |> Kernel.<>("\r\n")
  end

  defp rules(filters) do
    removed = for "!" <> name <- filters, do: name
    added = for filter <- filters, not String.starts_with?(filter, "!"), do: filter

    Enum.reject(@standing ++ added, &(&1 in removed))
  end

  # Each component becomes a sorted list of its surviving properties,
  # so order of properties and of components never matters.
  defp normalise(component, rules) do
    properties =
      component.properties
      |> Enum.reject(&dropped?(&1, rules))
      |> Enum.map(&render(&1, rules))
      |> Enum.sort()

    children = component.components |> Enum.map(&normalise(&1, rules)) |> Enum.sort()

    {component.name, properties, children}
  end

  # `NAME` drops the property; `NAME=VALUE` drops it only when it
  # carries that value; `NAME:PARAM` drops a parameter and leaves the
  # property in place, so it is not a reason to drop anything here.
  defp dropped?(property, rules) do
    Enum.any?(rules, &drops?(&1, property))
  end

  defp drops?(rule, property) do
    cond do
      String.contains?(rule, ":") ->
        false

      String.contains?(rule, "=") ->
        [name, value] = String.split(rule, "=", parts: 2)
        name == property.name and property.value == value

      true ->
        rule == property.name
    end
  end

  defp render(property, rules) do
    dropped = for rule <- rules, parameter = parameter_of(rule, property), do: parameter

    parameters =
      property.parameters
      |> Enum.reject(fn {name, _value} -> name in dropped end)
      |> Enum.sort()

    {property.name, parameters, property.value}
  end

  defp parameter_of(rule, property) do
    case String.split(rule, ":", parts: 2) do
      [name, parameter] when name == property.name -> parameter
      _not_this_property -> nil
    end
  end

  defp difference(same, same), do: :passed

  defp difference(left, right), do: {:failed, "calendar data differs: " <> describe(left, right)}

  # Reports the innermost component that differs rather than the
  # outermost, since every difference otherwise surfaces as
  # "VCALENDAR differs", which says nothing.
  defp describe({name, left_properties, left_children}, {_name, right_properties, right_children}) do
    cond do
      left_properties != right_properties ->
        missing = names(right_properties -- left_properties)
        extra = names(left_properties -- right_properties)
        "#{name} missing #{inspect(missing)}, unexpected #{inspect(extra)}"

      pair = mismatched(left_children, right_children) ->
        describe(elem(pair, 0), elem(pair, 1))

      length(left_children) != length(right_children) ->
        "#{name} has #{length(left_children)} components, expected #{length(right_children)}"

      # Equal counts and no pair matched: the two sides describe
      # different instances of the same thing — an override for one
      # date against an override for another — and saying "3
      # components, expected 3" describes nothing at all.
      pair = positioned(left_children, right_children) ->
        describe(elem(pair, 0), elem(pair, 1))

      true ->
        "#{name} components differ"
    end
  end

  defp positioned(left_children, right_children) do
    left_children
    |> Enum.zip(right_children)
    |> Enum.find(fn {left, right} -> left != right end)
  end

  # Pairs children by component name *and* the instance they describe,
  # so the report compares like with like. Name alone is not enough
  # once a recurrence has overrides: every `VEVENT` matches the first
  # one on the other side, and the report then explains the difference
  # between a series and one of its exceptions, which is every
  # difference and none of them.
  defp mismatched(left_children, right_children) do
    Enum.find_value(left_children, fn child ->
      case Enum.find(right_children, &counterpart?(&1, child)) do
        nil -> nil
        ^child -> nil
        other -> {child, other}
      end
    end)
  end

  defp counterpart?({name, right, _children}, {name, left, _left_children}),
    do: instance(right) == instance(left)

  defp counterpart?(_right, _left), do: false

  defp instance(properties) do
    Enum.find_value(properties, fn {name, _parameters, value} ->
      if name == "RECURRENCE-ID", do: value
    end)
  end

  # The property *name* is rarely enough to see what went wrong — both
  # sides usually have an ATTENDEE, and it is a parameter that differs.
  defp names(properties) do
    properties
    |> Enum.take(3)
    |> Enum.map_join(" | ", fn {name, parameters, value} ->
      "#{name}#{inspect(parameters)}:#{String.slice(value, 0, 30)}"
    end)
  end
end
