defmodule Dav.Cal.Availability do
  @moduledoc """
  When a person is available to be asked — RFC 7953.

  Free-busy answers "is this time already spoken for". Availability
  answers the prior question: "is this time one you would ever accept
  a meeting in". A calendar empty at three in the morning is not an
  invitation, and a server that reports only busy time invites one.

  RFC 7953 says that in a `VAVAILABILITY` component. It bounds a
  stretch of time and carries `AVAILABLE` sub-components saying when,
  inside that stretch, the person is open — the fixture case being
  *Monday to Friday, 09:00 to 17:00*, as a weekly rule. Everything in
  the stretch and outside those windows is reported back as busy with
  `FBTYPE=BUSY-UNAVAILABLE`, which a client draws differently from a
  meeting: not "they are in something" but "do not ask".

  ### Where it is kept

  Not in a calendar. `VAVAILABILITY` describes the person rather than
  an appointment, and storing it as an object would put it in every
  query answer that asked for the calendar's components. Apple's
  `CS:calendar-availability` property on the scheduling Inbox is where
  it goes, and this module both validates what is stored there — a
  value that is not calendar data is refused rather than kept for the
  free-busy code to trip over later — and reads it back when a
  busy-time request arrives.

  A `VAVAILABILITY` written into a calendar collection stays refused,
  by `Dav.Cal.Object`'s component rules. That is deliberate and the
  suite checks it.

  ### What is not implemented

  RFC 7953 section 3.1 lets overlapping `VAVAILABILITY` components be
  ranked by `PRIORITY`, so a narrower rule can override a broader one
  for a stretch. This reads every component as equally authoritative
  and unions their available time. The reference does the same for the
  single-component case the suite tests, and a priority model that no
  test exercises is a claim rather than a measurement.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Tempo.Compare

  @calendarserver "http://calendarserver.org/ns/"
  @property {@calendarserver, "calendar-availability"}

  # RFC 7953 section 3.1: what to call the time outside the available
  # windows. `BUSY-UNAVAILABLE` is the default, and the only value the
  # reference ever writes.
  @default_busytype "BUSY-UNAVAILABLE"

  @doc """
  The property availability is kept in.

  ### Returns

  * `CS:calendar-availability`, as a `t:Dav.Xml.qname/0`.

  ### Examples

      iex> Dav.Cal.Availability.property()
      {"http://calendarserver.org/ns/", "calendar-availability"}

  """
  @spec property() :: Xml.qname()
  def property, do: @property

  @doc """
  Availability is a property of a scheduling Inbox, not of a calendar.

  ### Arguments

  * `collection` is the collection being written into, unused.

  ### Returns

  * `false` — nothing here reacts to a write.

  ### Examples

      iex> Dav.Cal.Availability.applies?(nil)
      false

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: false
  def applies?(_collection), do: false

  @doc """
  A write changes nothing here.

  ### Arguments

  * `change` is the write, unused.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`.

  ### Examples

      iex> Dav.Cal.Availability.written(%{}, %{})
      :ok

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  Refuse an availability value that is not calendar data.

  A property nobody validates is a property the free-busy code has to
  distrust on every read. Refusing it at the point of storage means
  everything downstream can assume it parses.

  ### Arguments

  * `resource` is the resource being patched, unused.

  * `instruction` is one parsed `PROPPATCH` instruction.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok` for anything but a `CS:calendar-availability` being set, and
    for one whose value is a `VCALENDAR`.

  * `{:error, qname}` naming the property, for a value that is not.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VAVAILABILITY\\r\\nUID:1\\r\\nEND:VAVAILABILITY\\r\\nEND:VCALENDAR\\r\\n"
      iex> Dav.Cal.Availability.patchable(nil, {:set, Dav.Cal.Availability.property(), ics}, %{})
      :ok

      iex> Dav.Cal.Availability.patchable(nil, {:set, Dav.Cal.Availability.property(), "nope"}, %{})
      {:error, {"http://calendarserver.org/ns/", "calendar-availability"}}

      iex> Dav.Cal.Availability.patchable(nil, {:remove, Dav.Cal.Availability.property()}, %{})
      :ok

  """
  @impl Dav.Web.Hook
  @spec patchable(Resource.t() | nil, term(), map()) :: :ok | {:error, Xml.qname()}
  def patchable(_resource, {:set, @property, value}, _options) do
    if calendar?(value), do: :ok, else: {:error, @property}
  end

  def patchable(_resource, _instruction, _options), do: :ok

  defp calendar?(value) when is_binary(value) do
    match?({:ok, %{name: "VCALENDAR"}}, ICalendar.parse(value))
  end

  defp calendar?(_not_text), do: false

  @doc """
  The unavailable periods a stored availability implies, in a window.

  ### Arguments

  * `stated` is the `CS:calendar-availability` value, or `nil`.

  * `window` is the `{start, finish}` the busy-time report covers.

  * `floating` is the time zone unzoned values resolve in, or `nil`.

  ### Returns

  * A list of `{fbtype, {from, to}}` pairs — the same shape
    `Dav.Cal.FreeBusy.periods_of/3` returns, so the two go into one
    report together. Empty when nothing is stated, when the window is
    unbounded, or when the stated availability covers all of it.

  ### Examples

      iex> Dav.Cal.Availability.unavailable(nil, {nil, nil}, nil)
      []

  """
  @spec unavailable(binary() | nil, TimeRange.window(), String.t() | nil) ::
          [{String.t(), {Tempo.t(), Tempo.t()}}]
  def unavailable(nil, _window, _floating), do: []

  def unavailable(_stated, {nil, _finish}, _floating), do: []
  def unavailable(_stated, {_start, nil}, _floating), do: []

  def unavailable(stated, window, floating) do
    case ICalendar.parse(stated) do
      {:ok, calendar} -> stretches(calendar, window, floating)
      _unreadable -> []
    end
  end

  # Each `VAVAILABILITY` bounds the stretch it speaks for, and says
  # nothing about time outside it: a rule covering weekdays this year
  # makes no claim about next year, and reporting the gap as
  # unavailable would answer a question it was never asked.
  defp stretches(calendar, {start, finish}, floating) do
    for component <- calendar.components,
        component.name == "VAVAILABILITY",
        covered = clipped(TimeRange.periods(component, {start, finish}, floating), start, finish),
        {from, to} <- covered,
        gap <- outside(available(component, {from, to}, floating), {from, to}),
        do: {busytype(component), gap}
  end

  # A `VAVAILABILITY` with neither `DTEND` nor `DURATION` runs from its
  # `DTSTART` for as long as the question does — RFC 7953 section 3.1
  # calls that unbounded, and within one report the window is the
  # bound.
  defp clipped([], start, finish), do: [{start, finish}]
  defp clipped(periods, _start, _finish), do: periods

  defp available(component, window, floating) do
    component.components
    |> Enum.filter(&(&1.name == "AVAILABLE"))
    |> Enum.flat_map(&TimeRange.periods(&1, window, floating))
    |> merged()
  end

  defp busytype(component) do
    case Enum.find(component.properties, &(&1.name == "BUSYTYPE")) do
      %{value: stated} when stated != "" -> stated
      _unstated -> @default_busytype
    end
  end

  # The complement: the stretch minus the windows the person is open
  # in. Sorted and merged first, so a walk from one edge to the next
  # is enough.
  defp outside(open, {from, to}) do
    {gaps, last} =
      Enum.reduce(open, {[], from}, fn {began, ended}, {gaps, edge} ->
        {gaps ++ gap(edge, began), later(edge, ended)}
      end)

    gaps ++ gap(last, to)
  end

  defp gap(from, to), do: if(earlier?(from, to), do: [{from, to}], else: [])

  defp merged([]), do: []

  defp merged(periods) do
    [first | rest] = Enum.sort(periods, &sooner?/2)

    rest |> Enum.reduce([first], &absorb/2) |> Enum.reverse()
  end

  defp absorb({began, ended}, [{open, close} | done]) do
    if earlier?(close, began),
      do: [{began, ended}, {open, close} | done],
      else: [{open, later(close, ended)} | done]
  end

  defp sooner?({a, _first}, {b, _second}), do: not earlier?(b, a)

  defp later(a, b), do: if(earlier?(a, b), do: b, else: a)

  defp earlier?(a, b), do: Compare.compare_endpoints(a, b) == :earlier
end
