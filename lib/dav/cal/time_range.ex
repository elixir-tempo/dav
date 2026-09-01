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
  @spec overlaps?(
          ICalendar.component() | ICalendar.property(),
          {String.t() | nil, String.t() | nil},
          String.t() | nil,
          [ICalendar.component()]
        ) :: boolean()
  # A `time-range` inside a `prop-filter` tests the property's own
  # value — "a CREATED within this window" — rather than a component's
  # extent. RFC 4791 section 9.9 allows both, and the filter evaluator
  # is handed whichever the filter named, so this must recognise both
  # rather than assuming a component and crashing on a property.
  def overlaps?(component, range, floating \\ nil, siblings \\ [])

  def overlaps?(%{value: value, parameters: _parameters} = property, range, _floating, _siblings)
      when not is_map_key(property, :properties) do
    with {:ok, start} <- moment(elem(range, 0)),
         {:ok, finish} <- moment(elem(range, 1)),
         {:ok, moment} <- moment(value) do
      ends_after_start?(:instant, moment, start) and starts_before_end?(moment, finish)
    else
      _unreadable -> false
    end
  end

  # A VTODO is not an event with a different name. It may have no
  # DTSTART at all, and then its place on the timeline comes from DUE,
  # or COMPLETED, or CREATED, or nowhere — RFC 4791 section 9.9 gives
  # it a table of its own with seven rows. Running the VEVENT rules
  # over one finds nothing, because the first thing they look for is a
  # DTSTART that is not there.
  def overlaps?(%{name: "VTODO"} = todo, {from, to}, floating, _siblings) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to) do
      todo_overlaps?(todo, start, finish, floating)
    else
      _unreadable -> false
    end
  end

  def overlaps?(component, {from, to}, floating, siblings) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART", floating) do
      component
      |> occurrences(dtstart, extent(component, dtstart, floating), siblings, floating)
      |> Enum.any?(fn {_recurrence, instance, extent} ->
        instance_overlaps?(extent, instance, start, finish)
      end)
    else
      _no_dtstart_or_unreadable -> false
    end
  end

  @doc """
  Every instance of a component that falls inside a window.

  What `CALDAV:expand` needs: the moment the recurrence rule names,
  where the instance actually falls once overrides are applied, and
  how long it lasts.

  ### Arguments

  * `component` is the component to expand.

  * `range` is `{start, finish}`, either of which may be `nil`.

  * `floating` is the time zone to read a floating time in.

  * `siblings` are the other components describing the same event,
    whose overrides decide which instances survive and where.

  ### Returns

  * A list of `{recurrence_id, start, finish}`, in occurrence order.
    `recurrence_id` is `nil` for the initial instance, which names no
    occurrence; `finish` is `nil` for an instance with no extent of
    its own.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDURATION:PT1H\\r\\nRRULE:FREQ=DAILY;COUNT=3\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [event] = calendar.components
      iex> instances = Dav.Cal.TimeRange.instances_in(event, {"20260601T000000Z", "20260701T000000Z"})
      iex> length(instances)
      3

  """
  @spec instances_in(
          ICalendar.component(),
          {String.t() | nil, String.t() | nil},
          String.t() | nil,
          [ICalendar.component()]
        ) :: [{Tempo.t() | nil, Tempo.t(), Tempo.t() | nil}]
  def instances_in(component, range, floating \\ nil, siblings \\ [])

  def instances_in(component, {from, to}, floating, siblings) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART", floating) do
      component
      |> occurrences(dtstart, extent(component, dtstart, floating), siblings, floating)
      |> Enum.filter(fn {_recurrence, instance, extent} ->
        instance_overlaps?(extent, instance, start, finish)
      end)
      |> Enum.map(fn {recurrence, instance, extent} ->
        {recurrence, instance, lasts(extent, instance)}
      end)
    else
      _no_dtstart_or_unreadable -> []
    end
  end

  defp lasts(:instant, _instance), do: nil
  defp lasts(extent, instance), do: ending(extent, instance)

  @doc """
  Whether a moment is an occurrence of a component.

  `CANCEL` generation needs this: an organiser excluding a date that
  the previous rule never produced has not withdrawn anything, and a
  cancellation for it would name a meeting the recipient never had.

  ### Arguments

  * `component` is the component whose occurrences are asked about.

  * `parameters` are the iCalendar parameters the moment was written
    with — its `TZID`, when it has one.

  * `instance` is the moment, as written.

  ### Returns

  * `true` when the component's occurrence set contains the moment.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nRRULE:FREQ=DAILY;COUNT=3\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [event] = calendar.components
      iex> {Dav.Cal.TimeRange.occurs?(event, %{}, "20260616T090000Z"), Dav.Cal.TimeRange.occurs?(event, %{}, "20260630T090000Z")}
      {true, false}

  """
  @spec occurs?(ICalendar.component(), %{optional(String.t()) => String.t()}, String.t()) ::
          boolean()
  def occurs?(component, parameters, instance) do
    case property(component, "DTSTART") do
      %{value: value, parameters: written} = dtstart ->
        if zone_of(written, value, nil) == zone_of(parameters, instance, nil) and
             String.ends_with?(value, "Z") == String.ends_with?(instance, "Z") do
          occurs_on_the_clock?(component, dtstart, instance)
        else
          occurs_in_utc?(component, parameters, instance)
        end

      nil ->
        false
    end
  end

  # RFC 5545 section 3.8.5.3: a recurrence repeats in the *local* time
  # of its `DTSTART` — the weekly 15:00 stays 15:00 across a daylight
  # saving change. Expanding in UTC steps by exact weeks instead, so
  # after the change every occurrence is an hour off and no exclusion
  # matches. When the moment is written in the same zone as `DTSTART`,
  # both sides are compared as wall-clock readings and the zone never
  # enters into it.
  defp occurs_on_the_clock?(component, dtstart, instance) do
    with {:ok, start} when not is_nil(start) <- moment(dtstart.value),
         {:ok, moment} when not is_nil(moment) <- moment(instance) do
      ruled =
        case property(component, "RRULE") do
          nil -> [start]
          rule -> expand(rule.value, start)
        end

      added =
        for property <- component.properties,
            property.name == "RDATE",
            part <- String.split(property.value, ","),
            {:ok, extra} <- [moment(part)],
            not is_nil(extra),
            do: extra

      Enum.any?(ruled ++ added, &same_moment?(&1, moment))
    else
      _unreadable -> false
    end
  end

  # A moment written in a different zone than `DTSTART` has no shared
  # wall clock to compare on, so both sides convert to UTC.
  defp occurs_in_utc?(component, parameters, instance) do
    with {:ok, dtstart} <- property_value(component, "DTSTART", nil),
         {:ok, moment} when not is_nil(moment) <-
           moment(instance, zone_of(parameters, instance, nil)) do
      component
      |> starts(dtstart)
      |> Enum.any?(&same_moment?(&1, moment))
    else
      _unreadable -> false
    end
  end

  @doc """
  Whether an alarm fires inside a window.

  RFC 4791 section 9.9: a `time-range` on a `VALARM` is tested against
  when the alarm *goes off*, which the alarm does not state. It says
  how long before or after its parent it fires, so the instant is
  computed from the parent's start — or end, when the trigger says so
  — and an alarm that repeats fires more than once.

  ### Arguments

  * `alarm` is the `VALARM` component.

  * `parent` is the `VEVENT` or `VTODO` holding it.

  * `range` is `{start, finish}`, either of which may be `nil`.

  * `floating` is the time zone to read a floating parent time in.

  ### Returns

  * `true` when any firing falls inside the window.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nBEGIN:VALARM\\r\\nTRIGGER:-PT30M\\r\\nEND:VALARM\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [event] = calendar.components
      iex> [alarm] = event.components
      iex> Dav.Cal.TimeRange.alarm_overlaps?(alarm, event, {"20260615T082000Z", "20260615T084000Z"})
      true

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nBEGIN:VALARM\\r\\nTRIGGER:-PT30M\\r\\nEND:VALARM\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [event] = calendar.components
      iex> [alarm] = event.components
      iex> Dav.Cal.TimeRange.alarm_overlaps?(alarm, event, {"20260615T100000Z", "20260615T110000Z"})
      false

  """
  @spec alarm_overlaps?(
          ICalendar.component(),
          ICalendar.component(),
          {String.t() | nil, String.t() | nil},
          String.t() | nil,
          [ICalendar.component()]
        ) :: boolean()
  def alarm_overlaps?(alarm, parent, range, floating \\ nil, siblings \\ [])

  def alarm_overlaps?(alarm, parent, {from, to}, floating, siblings) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to) do
      alarm
      |> firings(parent, floating, siblings)
      |> Enum.any?(&instance_overlaps?(:instant, &1, start, finish))
    else
      _unreadable -> false
    end
  end

  # Every instant the alarm goes off: the first, and then one more for
  # each repeat.
  defp firings(alarm, parent, floating, siblings) do
    for first <- first_firing(alarm, parent, floating, siblings),
        instant <- [first | repeats(alarm, first)],
        do: instant
  end

  defp first_firing(alarm, parent, floating, siblings) do
    case property(alarm, "TRIGGER") do
      nil -> []
      trigger -> fired(trigger, parent, floating, siblings)
    end
  end

  # An absolute trigger names its own instant; a relative one is an
  # offset from the parent, by default from its start.
  defp fired(%{value: value, parameters: parameters}, parent, floating, siblings) do
    if Map.get(parameters, "VALUE") == "DATE-TIME" do
      case moment(value, zone_of(parameters, value, floating)) do
        {:ok, instant} -> [instant]
        _unreadable -> []
      end
    else
      parent
      |> anchors(Map.get(parameters, "RELATED", "START"), floating, siblings)
      |> Enum.map(&shifted(&1, value))
      |> Enum.reject(&is_nil/1)
    end
  end

  # One anchor per occurrence. A daily meeting with a warning half an
  # hour before rings every day, not only on the first — computing the
  # trigger from `DTSTART` alone finds the alarm once and misses every
  # later instance.
  defp anchors(parent, related, floating, siblings) do
    case property_value(parent, "DTSTART", floating) do
      {:ok, dtstart} ->
        parent
        |> occurrences(dtstart, extent(parent, dtstart, floating), siblings, floating)
        |> Enum.map(fn {_recurrence, instance, extent} ->
          anchored(instance, extent, parent, related)
        end)

      :error ->
        undated(parent, related, floating)
    end
    |> Enum.reject(&is_nil/1)
  end

  # A to-do need not have a start. RFC 5545 section 3.8.6.3 relates a
  # `VTODO` alarm to the start or the *end* of the to-do, and a to-do
  # with no start still has an end — its `DUE`. Without this an alarm
  # an hour before a deadline never fires.
  defp undated(%{name: "VTODO"} = todo, "END", floating) do
    case property_value(todo, "DUE", floating) do
      {:ok, due} -> starts(todo, due, floating)
      :error -> []
    end
  end

  defp undated(_parent, _related, _floating), do: []

  defp anchored(instance, extent, %{name: "VTODO"} = todo, "END") do
    case property_value(todo, "DUE", nil) do
      {:ok, due} -> due
      :error -> ended(instance, extent)
    end
  end

  defp anchored(instance, extent, _parent, "END"), do: ended(instance, extent)

  defp anchored(instance, _extent, _parent, _start), do: instance

  defp ended(instance, extent) do
    case ending(extent, instance) do
      %Tempo{} = finish -> finish
      _instant -> instance
    end
  end

  defp repeats(alarm, first) do
    with %{value: count} <- property(alarm, "REPEAT"),
         {times, _rest} when times > 0 <- Integer.parse(count),
         %{value: gap} <- property(alarm, "DURATION") do
      1..times
      |> Enum.reduce({[], first}, fn _each, seen -> again(seen, gap) end)
      |> elem(0)
    else
      _once_only -> []
    end
  end

  defp again({seen, previous}, gap) do
    case shifted(previous, gap) do
      nil -> {seen, previous}
      next -> {seen ++ [next], next}
    end
  end

  # The duration is read before it is applied: `Tempo.shift/2` wants a
  # parsed value, and an alarm's trigger is commonly negative — it
  # fires *before* the thing it warns about.
  defp shifted(instant, duration) do
    with {:ok, parsed} <- Tempo.from_iso8601(duration),
         %Tempo{} = moved <- Tempo.shift(instant, parsed) do
      moved
    else
      _unshiftable -> nil
    end
  rescue
    _bad_duration -> nil
  end

  @doc """
  The occurrences of a component inside a window, with their spans.

  Unlike `periods/4` the spans are not clipped to the window and each
  is returned separately — the caller is asking *which* occurrences
  fall inside, not how much busy time they add up to. Auto-scheduling
  needs it: a resource declines the occurrences it cannot host, by
  name.

  ### Arguments

  * `component` is the parsed component.

  * `range` is the `{from, to}` window, as iCalendar date-time
    strings.

  * `floating` is the zone floating times are read in, or `nil`.

  * `overridden` is the component's sibling overrides; occurrences
    they stand in for are left to them.

  ### Returns

  * A list of `{start, finish}` pairs, one per occurrence, in rule
    order.

  ### Examples

      iex> Dav.Cal.TimeRange.occurring(%{name: "VEVENT", properties: [], components: []}, {"20260101T000000Z", "20270101T000000Z"})
      []

  """
  @spec occurring(map(), {String.t(), String.t()}, String.t() | nil, [map()]) ::
          [{Tempo.t(), Tempo.t()}]
  def occurring(component, {from, to}, floating \\ nil, overridden \\ []) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART", floating) do
      component
      |> occurrences(dtstart, extent(component, dtstart, floating), overridden, floating)
      |> Enum.filter(fn {_recurrence, instance, extent} ->
        instance_overlaps?(extent, instance, start, finish)
      end)
      |> Enum.map(fn {_recurrence, at, was} -> {at, ending(was, at)} end)
    else
      _no_dtstart_or_unreadable -> []
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
  @spec periods(
          ICalendar.component(),
          {String.t() | nil, String.t() | nil},
          String.t() | nil,
          [ICalendar.component()]
        ) :: [{Tempo.t(), Tempo.t()}]
  def periods(component, range, floating \\ nil, overridden \\ [])

  def periods(component, {from, to}, floating, overridden) do
    with {:ok, start} <- moment(from),
         {:ok, finish} <- moment(to),
         {:ok, dtstart} <- property_value(component, "DTSTART", floating) do
      component
      |> occurrences(dtstart, extent(component, dtstart, floating), overridden, floating)
      |> Enum.filter(fn {_recurrence, instance, extent} ->
        instance_overlaps?(extent, instance, start, finish)
      end)
      |> Enum.map(fn {_recurrence, instance, extent} ->
        clip({instance, ending(extent, instance)}, start, finish)
      end)
      |> Enum.filter(fn {began, ended} -> earlier?(began, ended) end)
    else
      _no_dtstart_or_unreadable -> []
    end
  end

  # The moments a set of overrides stands in for. An occurrence that
  # has an override of its own is described by that override — the
  # rule still names the date, but what happens then is the override's
  # to say, and counting both reports the meeting twice.
  defp instances(overridden, floating) do
    for component <- overridden,
        {:ok, moment} <- [property_value(component, "RECURRENCE-ID", floating)],
        do: moment
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

  # The RFC presents this as a table keyed on which properties are
  # present, and it reads best kept that way: each row is one clause,
  # named by the state it applies to.
  defp todo_overlaps?(todo, start, finish, floating) do
    times = %{
      dtstart: optional(todo, "DTSTART", floating),
      due: optional(todo, "DUE", floating),
      completed: optional(todo, "COMPLETED", floating),
      created: optional(todo, "CREATED", floating),
      duration: property(todo, "DURATION")
    }

    todo
    |> todo_instances(times)
    |> Enum.any?(&todo_row(state(&1), &1, start, finish))
  end

  # A recurring to-do is due on each of its occurrences, not only the
  # first. The rule is anchored on `DTSTART` when there is one and on
  # `DUE` otherwise — a to-do commonly has only a deadline — and every
  # dated property moves with the occurrence.
  defp todo_instances(todo, times) do
    case anchor(times) do
      nil -> [times]
      first -> todo |> starts(first) |> Enum.map(&moved(times, first, &1))
    end
  end

  defp anchor(%{dtstart: nil, due: due}), do: due
  defp anchor(%{dtstart: dtstart}), do: dtstart

  defp moved(times, first, occurrence) do
    case gap(first, occurrence) do
      seconds when is_integer(seconds) and seconds != 0 ->
        %{times | dtstart: by(times.dtstart, seconds), due: by(times.due, seconds)}

      _same_or_unreadable ->
        times
    end
  end

  defp by(nil, _seconds), do: nil
  defp by(moment, seconds), do: shift(moment, seconds_iso(seconds))

  # Which row of the table applies, decided by presence alone. Written
  # as a match on the shape rather than a chain of conditionals, since
  # that is exactly what the RFC's leading `Y`/`N` columns are.
  defp state(times) do
    row(
      {present?(times.dtstart), present?(times.duration), present?(times.due),
       present?(times.completed), present?(times.created)}
    )
  end

  defp present?(value), do: not is_nil(value)

  defp row({true, true, _due, _completed, _created}), do: :dtstart_duration
  defp row({true, false, true, _completed, _created}), do: :dtstart_due
  defp row({true, false, false, _completed, _created}), do: :dtstart
  defp row({false, _duration, true, _completed, _created}), do: :due
  defp row({false, _duration, false, true, true}), do: :completed_created
  defp row({false, _duration, false, true, false}), do: :completed
  defp row({false, _duration, false, false, true}), do: :created
  defp row({false, _duration, false, false, false}), do: :undated

  # "(start <= DTSTART+DURATION) AND ((end > DTSTART) OR (end >= DTSTART+DURATION))"
  defp todo_row(:dtstart_duration, times, start, finish) do
    ends = shift(times.dtstart, times.duration.value)

    not_later?(start, ends) and (later?(finish, times.dtstart) or not_later?(ends, finish))
  end

  # "((start < DUE) OR (start <= DTSTART)) AND ((end > DTSTART) OR (end >= DUE))"
  defp todo_row(:dtstart_due, times, start, finish) do
    (earlier?(start, times.due) or not_later?(start, times.dtstart)) and
      (later?(finish, times.dtstart) or not_later?(times.due, finish))
  end

  defp todo_row(:dtstart, times, start, finish),
    do: not_later?(start, times.dtstart) and later?(finish, times.dtstart)

  defp todo_row(:due, times, start, finish),
    do: earlier?(start, times.due) and not_later?(times.due, finish)

  defp todo_row(:completed_created, times, start, finish) do
    (not_later?(start, times.created) or not_later?(start, times.completed)) and
      (not_later?(times.created, finish) or not_later?(times.completed, finish))
  end

  defp todo_row(:completed, times, start, finish),
    do: not_later?(start, times.completed) and not_later?(times.completed, finish)

  defp todo_row(:created, times, _start, finish), do: later?(finish, times.created)

  # A task with no times at all is always in range: there is no
  # evidence that it falls outside one.
  defp todo_row(:undated, _times, _start, _finish), do: true

  # An absent bound is an open end, and comparisons against it are
  # answered by the caller rather than here.
  defp optional(component, name, floating) do
    case property_value(component, name, floating) do
      {:ok, moment} -> moment
      :error -> nil
    end
  end

  # `earlier?/2` already answers an open end as true, so this only has
  # to flip the arguments.
  defp later?(a, b), do: earlier?(b, a)

  # "Time range tests MUST consider every recurrence instance ... if
  # any one instance matches, then the test returns true."
  #
  # The route matters: `Tempo.RRule.parse/2` yields a *repeating
  # interval* — `R5/2026-06-01T09:00:00Z/P1W` — and enumerating that
  # walks the instants inside it, second by second. Passing it through
  # `Tempo.to_interval_set/1` first turns the repetition into its
  # occurrences, which is what `Tempo.IntervalSet.members/1` then
  # returns.
  defp starts(component, dtstart), do: starts(component, dtstart, nil)

  # `RRULE` is only part of it. RFC 5545 section 3.8.5 builds the set
  # from the rule, plus every `RDATE`, minus every `EXDATE` — and an
  # `EXDATE` is how a client cancels one occurrence of a series
  # without an override, so ignoring it reports a meeting that was
  # called off.
  defp starts(component, dtstart, floating) do
    ruled =
      case property(component, "RRULE") do
        nil -> [dtstart]
        rule -> expand(rule.value, dtstart)
      end

    dropped = listed(component, "EXDATE", floating)

    (ruled ++ listed(component, "RDATE", floating))
    |> Enum.reject(fn instant -> Enum.any?(dropped, &same_moment?(instant, &1)) end)
    |> Enum.sort(&not_later?/2)
  end

  # `EXDATE` and `RDATE` each hold a comma-separated list, and a
  # component may carry more than one of either.
  defp listed(component, name, floating) do
    for property <- component.properties,
        property.name == name,
        part <- String.split(property.value, ","),
        {:ok, moment} <- [moment(part, zone_of(property.parameters, part, floating))],
        not is_nil(moment),
        do: moment
  end

  defp expand(rule, dtstart) do
    with {:ok, recurrence} <- RRule.parse(bounded(rule), from: dtstart),
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

  # A rule with neither `COUNT` nor `UNTIL` runs for ever, and an
  # unbounded recurrence cannot be turned into a set of intervals at
  # all — which left a monthly meeting looking like a single event on
  # one day. The horizon is applied as a count so that the rule can be
  # expanded; it is the same bound the expansion is truncated to.
  defp bounded(rule) do
    if rule =~ ~r/(^|;)\s*(COUNT|UNTIL)=/i, do: rule, else: rule <> ";COUNT=#{@horizon}"
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
  defp extent(component, dtstart, floating) do
    dtend = property_value(component, "DTEND", floating)
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

  # RFC 5545 section 3.8.4.4: `RANGE=THISANDFUTURE` on a
  # `RECURRENCE-ID` makes the override stand for the occurrence it
  # names *and every later one*. The later occurrences keep the rule's
  # spacing but move by the gap between the override's
  # `RECURRENCE-ID` and its `DTSTART`, and take the override's
  # duration with them — a meeting shifted two hours later "from now
  # on" is not still the old meeting at the old time.
  # Every occurrence the component actually has, as `{instant, extent}`
  # pairs, with any `RANGE=THISANDFUTURE` override applied. The extent
  # travels with the instant because an override may change the
  # duration as well as the time.
  defp occurrences(component, dtstart, extent, siblings, floating) do
    forward = forward_overrides(siblings, floating)
    replaced = instances(siblings, floating)

    for instant <- starts(component, dtstart, floating),
        not Enum.any?(replaced, &same_moment?(instant, &1)),
        {at, was} = continued(instant, extent, forward),
        do: {named(component, instant, dtstart, floating), at, was}
  end

  # Which occurrence this is. An override says so itself; for everything
  # else the rule's own moment names it — except the first, which RFC
  # 4791 section 9.6.5 leaves unnamed: "recurring components, other
  # than the initial instance, MUST include a RECURRENCE-ID property".
  defp named(component, instant, dtstart, floating) do
    case property_value(component, "RECURRENCE-ID", floating) do
      {:ok, stated} -> stated
      :error -> if same_moment?(instant, dtstart), do: nil, else: instant
    end
  end

  # Later overrides win, so they are applied in order and the last one
  # covering an occurrence is the one that describes it.
  defp continued(instant, extent, forward) do
    Enum.reduce(forward, {instant, extent}, fn {recurrence, gap, moved}, {at, was} ->
      if is_integer(gap) and later?(instant, recurrence) do
        {shift(at, seconds_iso(gap)), moved}
      else
        {at, was}
      end
    end)
  end

  # An override may move an occurrence earlier as well as later, and
  # ISO 8601 spells a negative duration with the sign in front of the
  # whole thing rather than inside it.
  defp seconds_iso(gap) when gap < 0, do: "-PT#{abs(gap)}S"
  defp seconds_iso(gap), do: "PT#{gap}S"

  defp forward_overrides(siblings, floating) do
    for override <- siblings,
        thisandfuture?(override),
        {:ok, recurrence} <- [property_value(override, "RECURRENCE-ID", floating)],
        {:ok, moved} <- [property_value(override, "DTSTART", floating)],
        do: {recurrence, gap(recurrence, moved), extent(override, moved, floating)}
  end

  defp thisandfuture?(component) do
    Enum.any?(component.properties, fn property ->
      property.name == "RECURRENCE-ID" and
        Map.get(property.parameters, "RANGE") == "THISANDFUTURE"
    end)
  end

  # Seconds between the occurrence the rule names and where the
  # override put it. `nil` when either will not convert, which leaves
  # the occurrence where the rule had it rather than moving it by a
  # guess.
  defp gap(recurrence, moved) do
    with {:ok, from} <- Tempo.to_elixir(recurrence),
         {:ok, to} <- Tempo.to_elixir(moved) do
      elapsed(to, from)
    else
      _unconvertible -> nil
    end
  end

  defp elapsed(%DateTime{} = to, %DateTime{} = from), do: DateTime.diff(to, from)

  defp elapsed(%NaiveDateTime{} = to, %NaiveDateTime{} = from), do: NaiveDateTime.diff(to, from)

  defp elapsed(_to, _from), do: nil

  defp property(component, name), do: Enum.find(component.properties, &(&1.name == name))

  # A `TZID` parameter is not decoration: `DTSTART;TZID=America/Los_
  # Angeles:20260615T090000` is 16:00 UTC, and reading it as 09:00 UTC
  # puts every event in the wrong place by hours — enough to move it
  # into or out of the window a client asked about. Comparisons here
  # are all against UTC instants, so the zone is applied on the way in.
  defp property_value(component, name, floating) do
    case property(component, name) do
      nil ->
        :error

      %{value: value, parameters: parameters} ->
        moment(value, zone_of(parameters, value, floating))
    end
  end

  # A value with no `TZID` and no trailing `Z` is *floating* — the same
  # wall-clock reading everywhere. RFC 4791 section 3.1 says a server
  # converting one for a `time-range` must use the `CALDAV:timezone`
  # from the request, or failing that the collection's
  # `CALDAV:calendar-timezone`. Reading it as UTC instead silently
  # moves every floating event by the collection's offset.
  defp zone_of(parameters, value, floating) do
    case Map.get(parameters, "TZID") do
      nil -> if String.ends_with?(value, "Z"), do: nil, else: floating
      zone -> zone
    end
  end

  defp moment(value, nil), do: moment(value)

  defp moment(value, zone) do
    with {:ok, parsed} <- moment(value),
         {:ok, naive} <- naive(parsed),
         {:ok, local} <- DateTime.from_naive(naive, zone),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC") do
      Tempo.from_iso8601(Calendar.strftime(utc, "%Y%m%dT%H%M%SZ"))
    else
      # An unresolvable zone leaves the value as written rather than
      # dropping the component: a time in an unknown zone is still
      # closer to right than no time at all.
      _unresolvable -> moment(value)
    end
  end

  # An all-day value converts too. `20270102` in New York begins at
  # 05:00 UTC, not at midnight UTC, and an all-day event compared as
  # though it were UTC starts five hours early — enough to fall inside
  # a window it does not belong to.
  defp naive(parsed) do
    case Tempo.to_naive_date_time(parsed) do
      {:ok, naive} -> {:ok, naive}
      _not_a_date_time -> midnight(parsed)
    end
  end

  defp midnight(parsed) do
    case Tempo.to_elixir(parsed) do
      {:ok, %Date{} = date} -> NaiveDateTime.new(date, ~T[00:00:00])
      _not_a_date -> :error
    end
  end

  defp moment(nil), do: {:ok, nil}
  defp moment(value) when is_binary(value), do: Tempo.from_iso8601(value)

  # Both sides are always present here: an open end is handled before
  # a comparison is reached, and a component with no DTSTART never
  # gets this far.
  defp earlier?(nil, _b), do: true
  defp earlier?(_a, nil), do: true
  defp earlier?(a, b), do: Compare.compare_endpoints(a, b) == :earlier

  defp same_moment?(a, b), do: Compare.compare_endpoints(a, b) == :same

  defp not_later?(nil, _b), do: true
  defp not_later?(_a, nil), do: true
  defp not_later?(a, b), do: Compare.compare_endpoints(a, b) in [:earlier, :same]
end
