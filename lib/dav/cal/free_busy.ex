defmodule Dav.Cal.FreeBusy do
  @moduledoc """
  The `CALDAV:free-busy-query` report — RFC 4791 section 7.10.

  *"When am I busy between these two dates"*, answered without
  disclosing what any of the appointments are. That distinction is the
  point of the report: free-busy is the one view of a calendar that
  can be shown to someone who may not read it, which is what makes
  scheduling across organisations possible.

      <C:free-busy-query xmlns:C="urn:ietf:params:xml:ns:caldav">
        <C:time-range start="20260601T000000Z" end="20260701T000000Z"/>
      </C:free-busy-query>

  Support for it is REQUIRED by the specification.

  ### It does not answer with a multistatus

  Every other report describes each resource in turn. This one
  computes a single value across a whole collection, and returns one
  iCalendar object with a `200`:

      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Dav//CalDAV//EN
      BEGIN:VFREEBUSY
      DTSTART:20260601T000000Z
      DTEND:20260701T000000Z
      DTSTAMP:20260601T120000Z
      FREEBUSY;FBTYPE=BUSY:20260615T090000Z/20260615T100000Z
      END:VFREEBUSY
      END:VCALENDAR

  ### Only busy time is reported

  Free time is the absence of busy time, so it is inferred rather than
  sent. A transparent or cancelled event is `FBTYPE=FREE` in the
  specification's table and therefore contributes nothing — it is left
  out entirely rather than written down as free.

  What survives is derived from `TRANSP` and `STATUS`, section 7.10:

  | `TRANSP` | `STATUS` | Reported as |
  | --- | --- | --- |
  | `OPAQUE`, or absent | `CONFIRMED`, or absent | `BUSY` |
  | `OPAQUE`, or absent | `TENTATIVE` | `BUSY-TENTATIVE` |
  | `OPAQUE`, or absent | `CANCELLED` | nothing |
  | `TRANSPARENT` | any | nothing |

  Periods of the same type that touch or overlap are coalesced, as the
  specification requires; periods of *different* types may overlap and
  are left alone.

  ### Limitations

  Times are computed in whatever frame the calendar data carries and
  written as UTC. Data that uses `TZID` with a `VTIMEZONE` definition
  is not converted, so a non-UTC `DTSTART` is reported at its written
  clock time. Access control is not consulted: the specification
  restricts the report to resources the user may read free-busy for,
  and this library has no notion of a user yet.

  """

  @behaviour Dav.Web.Report

  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml
  alias Tempo.Compare

  # The components the specification says to consider. Everything else
  # in a calendar — a VTODO, a VJOURNAL, a VTIMEZONE — says nothing
  # about whether its owner is occupied.
  @considered ["VEVENT", "VFREEBUSY"]

  @impl Dav.Web.Report
  def run(resource, body, depth, options)

  # "An attempt to run the report on a calendar object resource MUST
  # fail and return a 403 (Forbidden) status value."
  def run(%Resource{collection?: false}, _body, _depth, _options), do: {:error, :forbidden}

  def run(%Resource{} = collection, body, depth, options) do
    with {:ok, document} <- Xml.parse(body),
         {:ok, range} <- range_of(document) do
      periods =
        collection
        |> objects(depth, options)
        |> Enum.flat_map(&busy(&1, range, options))
        |> coalesce()

      {:ok, {:body, "text/calendar", write(periods, range, [])}}
    end
  end

  # "which MUST contain exactly one CALDAV:time-range XML element" —
  # so a body without one is not this report, and a `400` says so more
  # usefully than an empty answer would.
  defp range_of(%{children: children}) do
    case Enum.find(children, &local?(&1, "time-range")) do
      nil ->
        {:error, :malformed}

      element ->
        {:ok, {Map.get(element.attributes, "start"), Map.get(element.attributes, "end")}}
    end
  end

  # Depth bounds how far the collection is searched, not what is
  # described: `0` is the collection's own calendar objects and `1`
  # adds those of its child collections. A calendar home holding a
  # calendar each for work and for home is the case this exists for.
  defp objects(collection, depth, options) do
    {collections, objects} = split(collection, options)

    case depth do
      0 -> objects
      1 -> objects ++ Enum.flat_map(collections, &elem(split(&1, options), 1))
    end
  end

  defp split(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.split_with(children, & &1.collection?)
      _nothing -> {[], []}
    end
  end

  defp busy(object, range, options) do
    with {:ok, data} <- read(object, options),
         {:ok, calendar} <- ICalendar.parse(data) do
      calendar.components
      |> Enum.filter(&(&1.name in @considered))
      |> Enum.flat_map(&periods(&1, range))
    else
      _unreadable -> []
    end
  end

  defp read(object, %{store: store, context: context}) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(object, context), do: {:ok, IO.iodata_to_binary(data)}
    else
      :error
    end
  end

  # A VEVENT's busy time is when it happens. A VFREEBUSY's is already
  # stated by its FREEBUSY properties — it is a report, not an
  # appointment, so its own DTSTART bounds the report rather than
  # marking anyone as occupied.
  defp periods(%{name: "VEVENT"} = event, range) do
    case type(event) do
      nil -> []
      type -> Enum.map(TimeRange.periods(event, range), &{type, &1})
    end
  end

  defp periods(%{name: "VFREEBUSY"} = report, range) do
    for property <- report.properties,
        property.name == "FREEBUSY",
        period <- String.split(property.value, ","),
        {:ok, bounds} <- [within(period, range)],
        do: {Map.get(property.parameters, "FBTYPE", "BUSY"), bounds}
  end

  defp type(event) do
    transparent? = value(event, "TRANSP") == "TRANSPARENT"

    case {transparent?, value(event, "STATUS")} do
      {true, _any_status} -> nil
      {false, "CANCELLED"} -> nil
      {false, "TENTATIVE"} -> "BUSY-TENTATIVE"
      {false, _confirmed_or_absent} -> "BUSY"
    end
  end

  defp value(component, name) do
    case Enum.find(component.properties, &(&1.name == name)) do
      nil -> nil
      property -> property.value
    end
  end

  # A period is `start/end` or `start/duration`, and is reported only
  # for the part of it inside the window.
  defp within(period, {from, to}) do
    with [start, rest] <- String.split(period, "/", parts: 2),
         {:ok, began} <- Tempo.from_iso8601(start),
         {:ok, ended} <- finish(began, rest),
         {:ok, lower} <- moment(from),
         {:ok, upper} <- moment(to) do
      clipped = {later_of(began, lower), earlier_of(ended, upper)}
      if earlier?(elem(clipped, 0), elem(clipped, 1)), do: {:ok, clipped}, else: :error
    else
      _unreadable -> :error
    end
  end

  defp finish(began, rest) do
    case Tempo.from_iso8601(rest) do
      {:ok, value} -> {:ok, shift_or_take(began, value)}
      other -> other
    end
  end

  # `Tempo.shift/2` needs a duration; a second instant is already the
  # end. Which of the two was written is decided by whether shifting
  # succeeds, because both are ordinary ISO 8601 values.
  defp shift_or_take(began, value) do
    Tempo.shift(began, value)
  rescue
    _not_a_duration -> value
  end

  defp moment(nil), do: {:ok, nil}
  defp moment(value), do: Tempo.from_iso8601(value)

  # "Servers SHOULD coalesce consecutive or overlapping busy time
  # periods of the same type." Different types may overlap and are
  # gathered separately, so a tentative hold spanning a confirmed
  # meeting stays visible as both.
  defp coalesce(periods) do
    periods
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {type, bounds} -> {type, merge(Enum.sort(bounds, &sooner?/2))} end)
    |> Enum.reject(fn {_type, bounds} -> bounds == [] end)
  end

  defp merge([]), do: []
  defp merge([first | rest]), do: Enum.reverse(Enum.reduce(rest, [first], &absorb/2))

  defp absorb({began, ended}, [{open, close} | done]) do
    # Sorted by start, so the next period either extends the one being
    # built or begins a new one. Touching counts as continuous: two
    # back-to-back meetings are one stretch of being busy.
    if earlier?(close, began) do
      [{began, ended}, {open, close} | done]
    else
      [{open, later(close, ended)} | done]
    end
  end

  defp sooner?({a, _}, {b, _}), do: not earlier?(b, a)

  defp later(a, b), do: if(earlier?(a, b), do: b, else: a)

  defp later_of(moment, nil), do: moment
  defp later_of(moment, bound), do: if(earlier?(moment, bound), do: bound, else: moment)

  defp earlier_of(moment, nil), do: moment
  defp earlier_of(moment, bound), do: if(earlier?(bound, moment), do: bound, else: moment)

  defp earlier?(a, b), do: Compare.compare_endpoints(a, b) == :earlier

  @doc """
  The busy periods in a parsed calendar object.

  Shared with `Dav.Cal.Outbox`, because a busy-time request over a
  scheduling Outbox asks the same question as this report and must get
  the same answer — one computation, not two that can drift.

  ### Arguments

  * `calendar` is a component from `Dav.Cal.ICalendar.parse/1`.

  * `range` is the `{start, finish}` window.

  ### Returns

  * A list of `{fbtype, {from, to}}` pairs, uncoalesced.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDTEND:20260615T100000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> [{type, {_from, _to}}] = Dav.Cal.FreeBusy.periods_of(calendar, {"20260601T000000Z", "20260701T000000Z"})
      iex> type
      "BUSY"

  """
  @spec periods_of(ICalendar.component(), {String.t() | nil, String.t() | nil}) ::
          [{String.t(), {Tempo.t(), Tempo.t()}}]
  def periods_of(calendar, range) do
    calendar.components
    |> Enum.filter(&(&1.name in @considered))
    |> Enum.flat_map(&periods(&1, range))
  end

  @doc """
  Write a `VFREEBUSY` for a set of busy periods.

  ### Arguments

  * `periods` is a list of `{fbtype, {from, to}}` pairs.

  * `range` is the `{start, finish}` the report covers.

  ### Options

  * `:attendee` names the calendar user the report is about, for a
    scheduling response.

  * `:organizer` names the calendar user who asked.

  ### Returns

  * The iCalendar object, as a binary.

  ### Examples

      iex> Dav.Cal.FreeBusy.vfreebusy([], {"20260601T000000Z", "20260701T000000Z"})
      ...> |> String.contains?("BEGIN:VFREEBUSY")
      true

  """
  @spec vfreebusy(
          [{String.t(), {Tempo.t(), Tempo.t()}}],
          {String.t() | nil, String.t() | nil},
          keyword()
        ) ::
          binary()
  def vfreebusy(periods, range, options \\ []) do
    write(coalesce(periods), range, options)
  end

  ## --- writing ----------------------------------------------------

  defp write(periods, {from, to}, options) do
    lines =
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Dav//CalDAV//EN", "BEGIN:VFREEBUSY"] ++
        bound("DTSTART", from) ++
        bound("DTEND", to) ++
        bound("ORGANIZER", Keyword.get(options, :organizer)) ++
        bound("ATTENDEE", Keyword.get(options, :attendee)) ++
        ["DTSTAMP:" <> stamp()] ++
        Enum.map(periods, &freebusy/1) ++
        ["END:VFREEBUSY", "END:VCALENDAR"]

    lines
    |> Enum.map(&[ICalendar.fold(&1), "\r\n"])
    |> IO.iodata_to_binary()
  end

  defp bound(_name, nil), do: []
  defp bound(name, value), do: [name <> ":" <> value]

  defp freebusy({type, bounds}) do
    "FREEBUSY;FBTYPE=" <> type <> ":" <> Enum.map_join(bounds, ",", &period/1)
  end

  defp period({began, ended}), do: utc(began) <> "/" <> utc(ended)

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  # iCalendar wants the *basic* ISO 8601 form — `20260615T090000Z`,
  # not `2026-06-15T09:00:00Z` — which is why this does not go through
  # Tempo's own `to_iso8601/1`, whose output is Tempo's notation.
  #
  # `Tempo.to_elixir/1` chooses the native type the value actually is
  # rather than being told one, so it is asked first. It has no clause
  # for a value carrying a UTC offset, which is every value here, so
  # `to_naive_date_time/1` covers that until it does.
  defp utc(moment) do
    case native(moment) do
      {:ok, %Date{} = date} -> Calendar.strftime(date, "%Y%m%dT000000Z")
      {:ok, native} -> Calendar.strftime(native, "%Y%m%dT%H%M%SZ")
      _unconvertible -> inspect(moment)
    end
  end

  defp native(moment) do
    case Tempo.to_elixir(moment) do
      {:ok, native} -> {:ok, native}
      _shifted -> Tempo.to_naive_date_time(moment)
    end
  end

  defp local?(%{name: {_namespace, local}}, local), do: true
  defp local?(_element, _local), do: false
end
