defmodule Dav.Cal.Travel do
  @moduledoc """
  Getting there and back — Apple's travel time on a busy-time answer.

  An hour-long meeting across town does not occupy an hour. Apple's
  clients let each person record how long the journey takes them, in
  `X-APPLE-TRAVEL-DURATION` before the event and
  `X-APPLE-TRAVEL-RETURN-DURATION` after it, and a busy-time answer
  that ignores those offers the person a slot they cannot reach.

      DTSTART:20270104T230000Z
      DURATION:PT1H
      X-APPLE-TRAVEL-DURATION:PT30M
      X-APPLE-TRAVEL-RETURN-DURATION:PT25M

  is busy from `22:30Z` to `00:25Z`, not from `23:00Z` to `00:00Z`.

  ### It belongs to the person, not the meeting

  Two people at the same meeting travel different distances, so each
  copy of the event carries its own figure and neither is sent to the
  other. The properties are not among the extensions a deployment
  shares between participants, so `Dav.Cal.Scheduling` leaves them
  where they were written; on a shared calendar they are per-user
  data, and each sharee's busy time reflects their own journey to one
  event everybody can see.

  `X-APPLE-TRAVEL-START` and `X-APPLE-TRAVEL-RETURN` name where the
  journey begins and ends. They are read by clients drawing a map and
  say nothing about time, so nothing here looks at them.

  """

  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange

  @leading "X-APPLE-TRAVEL-DURATION"
  @trailing "X-APPLE-TRAVEL-RETURN-DURATION"

  @typedoc """
  How long before and after a component its travel takes.

  Held as the durations were written rather than parsed, because each
  reader wants its own sign: extending a busy period moves its start
  *earlier* by the leading figure, and widening a search window moves
  its start earlier by the *trailing* one.
  """
  @type t :: {leading :: String.t() | nil, trailing :: String.t() | nil}

  @doc """
  The travel a component records, read once.

  ### Arguments

  * `component` is a `t:Dav.Cal.ICalendar.component/0`.

  ### Returns

  * `{leading, trailing}` durations, either of which is `nil` when the
    component does not state it or states one that will not parse.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nX-APPLE-TRAVEL-DURATION:PT30M\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, %{components: [event]}} = Dav.Cal.ICalendar.parse(ics)
      iex> Dav.Cal.Travel.of(event)
      {"PT30M", nil}

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nSUMMARY:nearby\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, %{components: [event]}} = Dav.Cal.ICalendar.parse(ics)
      iex> Dav.Cal.Travel.of(event)
      {nil, nil}

  """
  @spec of(ICalendar.component()) :: t()
  def of(component) do
    {stated(component, @leading), stated(component, @trailing)}
  end

  @doc """
  Whether a component records any travel at all.

  ### Arguments

  * `travel` is a `t:t/0`.

  ### Returns

  * `false` when neither end of the journey is stated, which is the
    common case and the one worth not paying for.

  ### Examples

      iex> Dav.Cal.Travel.any?({nil, nil})
      false

  """
  @spec any?(t()) :: boolean()
  def any?({nil, nil}), do: false
  def any?(_travel), do: true

  @doc """
  Widen a query window by the travel either side of it.

  An event outside the window whose journey reaches into it makes the
  person busy inside it, so the occurrences have to be looked for over
  the wider stretch and trimmed back afterwards. Asking only about the
  window would report a slot free half an hour before a meeting nobody
  can get to in half an hour.

  ### Arguments

  * `window` is the `{start, finish}` the report covers.

  * `travel` is a `t:t/0`.

  ### Returns

  * The window, each open end left open and each bounded end moved
    outwards by the travel at that end.

  ### Examples

      iex> Dav.Cal.Travel.widened({nil, nil}, {nil, nil})
      {nil, nil}

  """
  @spec widened(TimeRange.window(), t()) :: TimeRange.window()
  def widened({start, finish}, {leading, trailing}) do
    {moved(start, trailing, :earlier), moved(finish, leading, :later)}
  end

  @doc """
  Extend a busy period by the travel either side of it.

  ### Arguments

  * `period` is a `{from, to}` pair.

  * `travel` is a `t:t/0`.

  ### Returns

  * The period, starting earlier by the leading travel and ending
    later by the trailing travel.

  ### Examples

      iex> {:ok, from} = Tempo.from_iso8601("2027-01-04T23:00:00Z")
      iex> {:ok, to} = Tempo.from_iso8601("2027-01-05T00:00:00Z")
      iex> {began, ended} = Dav.Cal.Travel.applied({from, to}, {"PT30M", nil})
      iex> {inspect(began), inspect(ended)}
      {~s(~o"2027Y1M4DT22H30M0SZ"), ~s(~o"2027Y1M5DT0H0M0SZ")}

  """
  @spec applied({Tempo.t(), Tempo.t()}, t()) :: {Tempo.t(), Tempo.t()}
  def applied({from, to}, {leading, trailing}) do
    {moved(from, leading, :earlier), moved(to, trailing, :later)}
  end

  # Kept only if it reads as a duration, so nothing downstream has to
  # decide what to do with `X-APPLE-TRAVEL-DURATION:soon`.
  defp stated(component, name) do
    with %{value: value} <- Enum.find(component.properties, &(&1.name == name)),
         {:ok, _duration} <- Tempo.parse_duration(signed(value, :later)) do
      value
    else
      _unstated_or_unreadable -> nil
    end
  end

  # A journey has a length rather than a direction; which way it moves
  # a moment is the caller's question, so the sign is applied here and
  # a client that wrote its own is not allowed to reverse the answer.
  defp signed(value, :later), do: String.trim_leading(value, "-")
  defp signed(value, :earlier), do: "-" <> signed(value, :later)

  defp moved(nil, _duration, _direction), do: nil
  defp moved(moment, nil, _direction), do: moment

  defp moved(moment, duration, direction) do
    with {:ok, parsed} <- Tempo.parse_duration(signed(duration, direction)),
         %Tempo{} = shifted <- Tempo.shift(moment, parsed) do
      shifted
    else
      _unshiftable -> moment
    end
  rescue
    _bad_duration -> moment
  end
end
