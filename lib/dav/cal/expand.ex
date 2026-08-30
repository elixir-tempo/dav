defmodule Dav.Cal.Expand do
  @moduledoc """
  Returning a recurrence as its instances — RFC 4791 section 9.6.5.

  A `CALDAV:calendar-data` element in a report may carry a
  `CALDAV:expand`:

      <C:calendar-data>
        <C:expand start="20260601T000000Z" end="20260701T000000Z"/>
      </C:calendar-data>

  which asks the server to replace the recurring components with one
  component per instance falling inside that range. Each instance
  states its own `RECURRENCE-ID` and carries no `RRULE`, `RDATE` or
  `EXDATE`, so a client can lay the month out without implementing
  recurrence at all — which is the point: expansion is the one part of
  iCalendar that a small client is most likely to get wrong, and the
  server already has to do it to answer a `time-range`.

  Times come back in UTC, so an expanded object needs no `VTIMEZONE`
  and does not carry one. An all-day instance stays a date, because
  converting it to an instant would move it into whichever day the
  offset lands in.

  """

  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange
  alias Dav.Xml

  @typedoc "The range to expand across, or `nil` when none was asked for."
  @type t :: {String.t() | nil, String.t() | nil} | nil

  @doc """
  The range a report asked to expand across.

  ### Arguments

  * `element` is the `calendar-data` element from the request, or
    `nil`.

  ### Returns

  * `{start, finish}` when the client asked for expansion; or

  * `nil` when it did not.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"><C:expand start="20260601T000000Z" end="20260701T000000Z"/></C:calendar-data>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Expand.from_element(element)
      {"20260601T000000Z", "20260701T000000Z"}

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"/>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Expand.from_element(element)
      nil

  """
  @spec from_element(Xml.element() | nil) :: t()
  def from_element(nil), do: nil

  def from_element(element) do
    case Enum.find(element.children, &local?(&1, "expand")) do
      nil -> nil
      found -> {Map.get(found.attributes, "start"), Map.get(found.attributes, "end")}
    end
  end

  @doc """
  Replace a calendar object's recurrences with their instances.

  ### Arguments

  * `data` is the object as stored.

  * `range` is the `t:t/0` the client asked for, or `nil`.

  * `floating` is the time zone to read a floating time in.

  ### Returns

  * The object with each recurrence replaced by its instances, as
    iCalendar text. Data that cannot be parsed is returned unchanged —
    an expansion is a request to reshape the answer, not a reason to
    withhold it.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nDTSTART:20260615T090000Z\\r\\nDURATION:PT1H\\r\\nRRULE:FREQ=DAILY;COUNT=3\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> expanded = Dav.Cal.Expand.apply(ics, {"20260601T000000Z", "20260701T000000Z"}, nil)
      iex> {String.contains?(expanded, "RECURRENCE-ID:20260617T090000Z"), String.contains?(expanded, "RRULE")}
      {true, false}

  """
  @spec apply(binary(), t(), String.t() | nil) :: binary()
  def apply(data, nil, _floating), do: data

  def apply(data, range, floating) do
    case ICalendar.parse(data) do
      {:ok, calendar} -> calendar |> expanded(range, floating) |> ICalendar.write()
      _unreadable -> data
    end
  end

  # Every time in the answer is UTC, so the definitions that existed to
  # interpret them have nothing left to say.
  defp expanded(calendar, range, floating) do
    dated = Enum.reject(calendar.components, &(&1.name == "VTIMEZONE"))

    %{calendar | components: Enum.flat_map(dated, &instances(&1, dated, range, floating))}
  end

  defp instances(component, dated, range, floating) do
    siblings = Enum.reject(dated, &(&1 == component))

    for {recurrence, start, finish} <-
          TimeRange.instances_in(component, range, floating, siblings),
        instance = instance(component, recurrence, start, finish),
        not is_nil(instance),
        do: instance
  end

  defp instance(component, recurrence, start, finish) do
    case restated(component, "DTSTART", start) do
      {:ok, dtstart} ->
        stated = named(component, recurrence) ++ [dtstart | ended(component, finish)]
        %{component | properties: rebuilt(component, stated)}

      :error ->
        nil
    end
  end

  # The initial instance names no occurrence — RFC 4791 section 9.6.5
  # asks for a `RECURRENCE-ID` on "recurring components, other than
  # the initial instance", and one on the first would say the series
  # begins with an override of itself.
  defp named(_component, nil), do: []

  defp named(component, recurrence) do
    case restated(component, "RECURRENCE-ID", recurrence) do
      {:ok, id} -> [id]
      :error -> []
    end
  end

  # The rule and its exceptions have been spent producing this
  # instance, so they are not restated: a client reading them again
  # would expand the expansion.
  @dropped ~w(RRULE RDATE EXDATE DTSTART DTEND RECURRENCE-ID)

  defp rebuilt(component, stated) do
    kept = for property <- component.properties, property.name not in @dropped, do: property

    stated ++ kept
  end

  # A `DURATION` says the same thing about every instance and is left
  # alone; a `DTEND` names a moment, and each instance has its own.
  defp ended(component, finish) do
    with %{} <- Enum.find(component.properties, &(&1.name == "DTEND")),
         {:ok, dtend} <- restated(component, "DTEND", finish) do
      [dtend]
    else
      _no_dtend_or_unstampable -> []
    end
  end

  # The instance's own value, in UTC — or as a date, when the property
  # it comes from was one. A date shifted into an offset lands in
  # whichever day the offset reaches, which is not the day the client
  # asked about.
  defp restated(component, name, moment) do
    source = Enum.find(component.properties, &(&1.name == "DTSTART"))

    case stamp(moment, date?(source)) do
      nil -> :error
      value -> {:ok, %{name: name, parameters: parameters(source), value: value}}
    end
  end

  defp parameters(nil), do: %{}

  defp parameters(source) do
    source.parameters |> Map.drop(["TZID"]) |> Map.take(["VALUE"])
  end

  defp date?(nil), do: false

  defp date?(property) do
    Map.get(property.parameters, "VALUE") == "DATE" or not String.contains?(property.value, "T")
  end

  defp stamp(moment, date?) do
    case {Tempo.to_elixir(moment), date?} do
      {{:ok, %Date{} = date}, _date?} -> Calendar.strftime(date, "%Y%m%d")
      {{:ok, moment}, true} -> Calendar.strftime(moment, "%Y%m%d")
      {{:ok, moment}, false} -> Calendar.strftime(moment, "%Y%m%dT%H%M%SZ")
      {_unconvertible, _date?} -> nil
    end
  end

  defp local?(%{name: {_namespace, local}}, local), do: true
  defp local?(_element, _local), do: false
end
