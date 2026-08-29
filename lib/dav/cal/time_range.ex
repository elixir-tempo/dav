defmodule Dav.Cal.TimeRange do
  @moduledoc """
  Does a component fall inside a `CALDAV:time-range` — RFC 4791 section 9.9.

  This is the half of filtering that needs *meaning* rather than
  structure, and it is Tempo's: iCalendar's `20260601T000000Z`,
  `2026-06-01`, `PT1H` and `P1D` are all ordinary ISO 8601 values that
  `Tempo.from_iso8601/1` reads directly, so nothing here converts
  between formats.

  ### The rule is a table, not an intersection

  The obvious implementation — build an interval and intersect — is
  wrong, and the specification spells out why in five cases. What a
  component's period *is* depends on which properties it has:

  | `DTEND` | `DURATION` | `> 0` | `DTSTART` is date-time | Condition |
  | --- | --- | --- | --- | --- |
  | yes | — | — | — | `start < DTEND and end > DTSTART` |
  | no | yes | yes | — | `start < DTSTART+DURATION and end > DTSTART` |
  | no | yes | no | — | `start <= DTSTART and end > DTSTART` |
  | no | no | — | yes | `start <= DTSTART and end > DTSTART` |
  | no | no | — | no | `start < DTSTART+P1D and end > DTSTART` |

  The distinction that catches people is `<` against `<=`: a
  zero-length event exactly at `start` overlaps, while an event that
  *ends* exactly at `start` does not. `start` is inclusive and `end`
  is not, so treating both alike drops or duplicates events at the
  boundaries of every window a client asks for.

  A missing `start` or `end` means minus or plus infinity — the range
  is open at that side, not empty.

  """

  alias Dav.Cal.ICalendar
  alias Tempo.Compare
  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.RRule

  # How many occurrences of a recurrence are ever expanded. Bounded
  # deliberately: an unbounded rule expanded eagerly is a denial of
  # service reachable from a query body.
  @horizon 500

  @doc """
  Whether a component overlaps the range.

  Every recurrence instance is considered, as the specification
  requires: one match anywhere is a match. A component with no
  `DTSTART` cannot be placed and never overlaps.

  ### Arguments

  * `component` is a component from `Dav.Cal.ICalendar.parse/1`.

  * `range` is `{start, finish}`, either of which may be `nil` for an
    open end. Both are iCalendar date-with-UTC-time strings.

  ### Returns

  * `true` when the component, or any instance of it, overlaps.

  ### Examples

      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse("BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDTEND:20260615T100000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n")
      iex> [event] = calendar.components
      iex> Dav.Cal.TimeRange.overlaps?(event, {"20260615T000000Z", "20260616T000000Z"})
      true

      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse("BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDTEND:20260615T100000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n")
      iex> [event] = calendar.components
      iex> Dav.Cal.TimeRange.overlaps?(event, {"20260701T000000Z", nil})
      false

  """
  @spec overlaps?(ICalendar.component(), {String.t() | nil, String.t() | nil}) :: boolean()
  def overlaps?(component, {from, to}) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART") do
      extent = extent(component, dtstart)

      component
      |> starts(dtstart)
      |> Enum.any?(&instance_overlaps?(extent, &1, start, finish))
    else
      _no_dtstart_or_unreadable -> false
    end
  end

  @doc """
  The periods a component is busy for, clipped to the range.

  `overlaps?/2` answers whether a component is in the window;
  this answers *when*, which is what `CALDAV:free-busy-query` reports.
  Every recurrence instance inside the window contributes its own
  period.

  Periods are clipped to the range — a week-long event overlapping a
  one-day window is busy for that day, not for the week — and
  zero-length periods are dropped, since a busy period of no duration
  says nothing.

  ### Arguments

  * `component` is a component from `Dav.Cal.ICalendar.parse/1`.

  * `range` is `{start, finish}`, either of which may be `nil`.

  ### Returns

  * A list of `{from, to}` pairs of `t:Tempo.t/0`, in the order the
    instances occur.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDTEND:20260615T100000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [event] = calendar.components
      iex> [{from, to}] = Dav.Cal.TimeRange.periods(event, {"20260601T000000Z", "20260701T000000Z"})
      iex> {inspect(from), inspect(to)}
      {~s(~o"2026Y6M15DT9H0M0SZ"), ~s(~o"2026Y6M15DT10H0M0SZ")}

  """
  @spec periods(ICalendar.component(), {String.t() | nil, String.t() | nil}) ::
          [{Tempo.t(), Tempo.t()}]
  def periods(component, {from, to}) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART") do
      extent = extent(component, dtstart)

      component
      |> starts(dtstart)
      |> Enum.filter(&instance_overlaps?(extent, &1, start, finish))
      |> Enum.map(&clip({&1, ending(extent, &1)}, start, finish))
      |> Enum.filter(fn {began, ended} -> earlier?(began, ended) end)
    else
      _no_dtstart_or_unreadable -> []
    end
  end

  defp ending(:instant, instance), do: instance
  defp ending({:for, duration}, instance), do: Tempo.shift(instance, duration)
  defp ending({:lasting, iso}, instance), do: shift(instance, iso)

  # The window bounds what is reported, not what happened: an event
  # running past either edge is busy up to the edge and no further.
  defp clip({began, ended}, start, finish) do
    {later_of(began, start), earlier_of(ended, finish)}
  end

  defp later_of(moment, nil), do: moment
  defp later_of(moment, bound), do: if(earlier?(moment, bound), do: bound, else: moment)

  defp earlier_of(moment, nil), do: moment
  defp earlier_of(moment, bound), do: if(earlier?(bound, moment), do: bound, else: moment)

  # "Time range tests MUST consider every recurrence instance ... if
  # any one instance matches, then the test returns true."
  #
  # The route matters: `Tempo.RRule.parse/2` yields a *repeating
  # interval* — `R5/2026-06-01T09:00:00Z/P1W` — and enumerating that
  # walks the instants inside it, second by second. Passing it through
  # `Tempo.to_interval_set/1` first turns the repetition into its
  # occurrences, which is what `Tempo.IntervalSet.members/1` then
  # returns.
  defp starts(component, dtstart) do
    case property(component, "RRULE") do
      nil -> [dtstart]
      rule -> expand(rule.value, dtstart)
    end
  end

  defp expand(rule, dtstart) do
    with {:ok, recurrence} <- RRule.parse(rule, from: dtstart),
         {:ok, set} <- Tempo.to_interval_set(recurrence) do
      set
      |> IntervalSet.members()
      |> Enum.take(@horizon)
      |> Enum.map(&Interval.from/1)
    else
      # An unreadable rule falls back to the single start rather than
      # dropping the component entirely.
      _unreadable -> [dtstart]
    end
  rescue
    _unreadable -> [dtstart]
  end

  defp instance_overlaps?(extent, instance, start, finish) do
    ends_after_start?(extent, instance, start) and starts_before_end?(instance, finish)
  end

  # The *effective* extent of an occurrence. A recurring event's
  # written `DTEND` belongs to its first instance only — the
  # specification requires inferring one per occurrence — so the
  # length is measured once and applied to each instance's start.
  # Comparing a later instance against the original `DTEND` is how a
  # weekly event silently stops matching after its first week.
  defp extent(component, dtstart) do
    dtend = property_value(component, "DTEND")
    duration = property(component, "DURATION")

    cond do
      match?({:ok, _moment}, dtend) -> lasting(dtstart, elem(dtend, 1))
      duration && positive?(duration.value) -> {:lasting, duration.value}
      duration -> :instant
      date_only?(component) -> {:lasting, "P1D"}
      true -> :instant
    end
  end

  defp lasting(dtstart, dtend) do
    case Tempo.duration(dtstart, dtend) do
      {:ok, duration} -> {:for, duration}
      _unmeasurable -> :instant
    end
  rescue
    _unmeasurable -> :instant
  end

  # A zero-length occurrence at exactly `start` overlaps, so the
  # comparison is `<=`; one that *ends* at `start` does not, so where
  # there is length the comparison is strict.
  defp ends_after_start?(_extent, _instance, nil), do: true
  defp ends_after_start?(:instant, instance, start), do: not_later?(start, instance)

  defp ends_after_start?({:for, duration}, instance, start) do
    earlier?(start, Tempo.shift(instance, duration))
  end

  defp ends_after_start?({:lasting, iso}, instance, start) do
    earlier?(start, shift(instance, iso))
  end

  defp starts_before_end?(_dtstart, nil), do: true
  defp starts_before_end?(dtstart, finish), do: earlier?(dtstart, finish)

  # A DTSTART written as a date, or declared `VALUE=DATE`, is a whole
  # day; one written as a date-time is an instant.
  defp date_only?(component) do
    case property(component, "DTSTART") do
      nil ->
        false

      dtstart ->
        Map.get(dtstart.parameters, "VALUE") == "DATE" or not String.contains?(dtstart.value, "T")
    end
  end

  defp positive?(duration) do
    case Tempo.from_iso8601(duration) do
      {:ok, value} -> not String.contains?(inspect(value), "PT0S") and duration != "PT0S"
      _unreadable -> false
    end
  end

  defp shift(moment, duration) do
    case Tempo.from_iso8601(duration) do
      {:ok, amount} -> Tempo.shift(moment, amount)
      _unreadable -> moment
    end
  end

  defp property(component, name), do: Enum.find(component.properties, &(&1.name == name))

  defp property_value(component, name) do
    case property(component, name) do
      nil -> :error
      %{value: value} -> moment(value)
    end
  end

  defp moment(nil), do: {:ok, nil}
  defp moment(value) when is_binary(value), do: Tempo.from_iso8601(value)

  # Both sides are always present here: an open end is handled before
  # a comparison is reached, and a component with no DTSTART never
  # gets this far.
  defp earlier?(a, b), do: Compare.compare_endpoints(a, b) == :earlier

  defp not_later?(a, b), do: Compare.compare_endpoints(a, b) in [:earlier, :same]
end
