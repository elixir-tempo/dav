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

  alias Dav.Cal.Delegation
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml
  alias Tempo.Compare

  # The components the specification says to consider. Everything else
  # in a calendar — a VTODO, a VJOURNAL, a VTIMEZONE — says nothing
  # about whether its owner is occupied.
  @considered ["VEVENT", "VFREEBUSY"]

  # The busy types written as two instants rather than as a start and
  # a duration — see `period/2`.
  @bounded ~w(BUSY-UNAVAILABLE)

  @impl Dav.Web.Report
  def run(resource, body, depth, options)

  # "An attempt to run the report on a calendar object resource MUST
  # fail and return a 403 (Forbidden) status value."
  def run(%Resource{collection?: false}, _body, _depth, _options), do: {:error, :forbidden}

  def run(%Resource{} = collection, body, depth, options) do
    if Schedule.inbox?(collection) or Schedule.outbox?(collection),
      do: {:error, {Xml.dav(), "supported-report"}},
      else: query(collection, body, depth, options)
  end

  # RFC 6638 section 2.2: the scheduling Inbox and Outbox hold copies
  # of messages, not the calendar itself — a free-busy answer computed
  # over them would double-count every invitation still sitting there.
  # The report is simply not supported on either.
  defp query(collection, body, depth, options) do
    with {:ok, document} <- Xml.parse(body),
         {:ok, range} <- range_of(document),
         {:ok, window} <- TimeRange.bounds(range) do
      periods =
        collection
        |> objects(depth, options)
        |> Enum.reject(fn {object, _floating} -> Delegation.busy_excluded?(object, options) end)
        |> Enum.flat_map(fn {object, floating} -> busy(object, window, floating, options) end)
        |> coalesce()

      {:ok, {:body, "text/calendar", write(periods, range, [])}}
    else
      :error -> {:error, :malformed}
      refusal -> refusal
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
        bounds = {Map.get(element.attributes, "start"), Map.get(element.attributes, "end")}

        # RFC 4791 section 9.9: each bound is "a date with UTC time".
        # A plain date or a floating date-time names no instant, and
        # answering one would mean picking a zone for the client.
        if Enum.all?(Tuple.to_list(bounds), &utc_bound?/1),
          do: {:ok, bounds},
          else: {:error, :malformed}
    end
  end

  defp utc_bound?(nil), do: true
  defp utc_bound?(value) when is_binary(value), do: Regex.match?(~r/^\d{8}T\d{6}Z$/, value)
  defp utc_bound?(_other), do: false

  # Depth bounds how far the collection is searched, not what is
  # described: `0` is the collection's own calendar objects and `1`
  # adds those of its child collections. A calendar home holding a
  # calendar each for work and for home is the case this exists for.
  # Each object paired with the zone its own calendar reads floating
  # times in. A report over a whole home spans collections that may
  # disagree — one states a time zone, the next does not — and reading
  # them all in the target's zone moves half the events by an hour or
  # more.
  defp objects(collection, depth, options) do
    {collections, objects} = split(collection, options)

    within = fn holder, held ->
      for object <- held, do: {object, collection_zone(holder, options)}
    end

    case depth do
      0 ->
        within.(collection, objects)

      1 ->
        within.(collection, objects) ++
          Enum.flat_map(collections, &within.(&1, elem(split(&1, options), 1)))

      # A home may hold calendars inside collections inside
      # collections, and `Depth: infinity` asks about all of them. A
      # bounded walk would answer for part of somebody's time and
      # report the rest as free.
      :infinity ->
        within.(collection, objects) ++
          Enum.flat_map(collections, &objects(&1, :infinity, options))
    end
  end

  defp split(collection, %{store: store, context: context} = options) do
    case store.children(collection, context) do
      {:ok, children} ->
        {collections, objects} = Enum.split_with(children, & &1.collection?)

        {Enum.reject(collections, &transparent?(&1, options)), objects}

      _nothing ->
        {[], []}
    end
  end

  @doc """
  Whether a calendar collection is excluded from its owner's busy time.

  RFC 6638 section 9.1: a calendar marked `transparent` does not
  contribute. A calendar shared to someone is the usual case — the
  sharer's commitments are not theirs, and counting them reports them
  busy for meetings they were merely shown.

  ### Arguments

  * `collection` is the calendar collection.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `true` when the collection declares `CALDAV:schedule-calendar-transp`
    as `transparent`, and `false` otherwise — including when the store
    holds no properties at all, since the default is opaque.

  ### Examples

      iex> Dav.Cal.FreeBusy.transparent?(%Dav.Web.Resource{}, %{store: Dav.Web.Store, context: nil})
      false

  """
  @spec transparent?(Resource.t(), map()) :: boolean()
  def transparent?(collection, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(collection, context) do
      properties |> Map.get({Xml.caldav(), "schedule-calendar-transp"}) |> says_transparent?()
    else
      _opaque -> false
    end
  end

  defp says_transparent?({:elements, _namespaces, markup}),
    do: String.contains?(markup, "transparent")

  defp says_transparent?({:names, names}),
    do: Enum.any?(names, fn {_namespace, local} -> local == "transparent" end)

  defp says_transparent?(_opaque), do: false

  defp busy(object, range, floating, options) do
    with {:ok, data} <- read(object, options),
         {:ok, calendar} <- ICalendar.parse(data) do
      periods_of(calendar, range, floating)
    else
      _unreadable -> []
    end
  end

  # RFC 4791 section 3.1, the same rule the calendar-query follows: an
  # event written without a zone happens in the collection's
  # `CALDAV:calendar-timezone`. Reading it as UTC instead moves it by
  # that offset, which is enough to report someone free during a
  # meeting they are sitting in.
  defp collection_zone(collection, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(collection, context),
         value when is_binary(value) <-
           Map.get(properties, {Xml.caldav(), "calendar-timezone"}),
         [_line, zone] <- Regex.run(~r/^TZID:(.+)$/m, value) do
      String.trim(zone)
    else
      _absent -> nil
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
  defp periods(%{name: "VEVENT"} = event, range, floating, overrides) do
    case type(event) do
      nil -> []
      type -> Enum.map(TimeRange.periods(event, range, floating, overrides), &{type, &1})
    end
  end

  defp periods(%{name: "VFREEBUSY"} = report, range, _floating, _overrides) do
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

  @doc """
  Whether any period in one set overlaps any period in another.

  ### Arguments

  * `some` is a list of `{fbtype, {from, to}}` pairs, as
    `periods_of/3` returns.

  * `others` is another such list.

  ### Returns

  * `true` when some period in the first set intersects one in the
    second.

  ### Examples

      iex> Dav.Cal.FreeBusy.overlapping?([], [])
      false

  """
  @spec overlapping?(
          [{String.t(), {Tempo.t(), Tempo.t()}}],
          [{String.t(), {Tempo.t(), Tempo.t()}}]
        ) :: boolean()
  def overlapping?(some, others) do
    Enum.any?(some, fn {_type, {from, to}} ->
      Enum.any?(others, fn {_other, {begins, ends}} ->
        earlier?(begins, to) and earlier?(from, ends)
      end)
    end)
  end

  defp value(component, name) do
    case Enum.find(component.properties, &(&1.name == name)) do
      nil -> nil
      property -> property.value
    end
  end

  # A period is `start/end` or `start/duration`, and is reported only
  # for the part of it inside the window.
  defp within(period, {lower, upper}) do
    with [start, rest] <- String.split(period, "/", parts: 2),
         {:ok, began} <- Tempo.from_iso8601(start),
         {:ok, ended} <- finish(began, rest) do
      clipped = {later_of(began, lower), earlier_of(ended, upper)}
      if earlier?(elem(clipped, 0), elem(clipped, 1)), do: {:ok, clipped}, else: :error
    else
      _unreadable -> :error
    end
  end

  # RFC 5545 section 3.3.9: a period ends with either an instant or a
  # duration, so both are tried by name rather than asking the general
  # grammar which of the two — or of anything else — it was.
  defp finish(began, rest) do
    case Tempo.parse_duration(rest) do
      {:ok, amount} -> {:ok, shift_or_take(began, amount)}
      _not_a_duration -> ended_at(began, rest)
    end
  end

  defp ended_at(began, rest) do
    case Tempo.parse_datetime(rest) do
      {:ok, instant} -> {:ok, shift_or_take(began, instant)}
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

  * `range` is the window, as read by `Dav.Cal.TimeRange.bounds/1`.

  ### Returns

  * A list of `{fbtype, {from, to}}` pairs, uncoalesced.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nDTSTART:20260615T090000Z\\r\\nDTEND:20260615T100000Z\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse(ics)
      iex> {:ok, window} = Dav.Cal.TimeRange.bounds({"20260601T000000Z", "20260701T000000Z"})
      iex> [{type, {_from, _to}}] = Dav.Cal.FreeBusy.periods_of(calendar, window)
      iex> type
      "BUSY"

  """
  @spec periods_of(ICalendar.component(), TimeRange.window(), String.t() | nil) ::
          [{String.t(), {Tempo.t(), Tempo.t()}}]
  def periods_of(calendar, range, floating \\ nil) do
    considered = Enum.filter(calendar.components, &(&1.name in @considered))
    overrides = Enum.filter(considered, &(not is_nil(value(&1, "RECURRENCE-ID"))))

    # Overrides stand in for the master's rule-produced instances, so
    # only the master's expansion is trimmed by them. An override
    # handed its own recurrence set would suppress the one instance it
    # exists to describe.
    Enum.flat_map(considered, fn component ->
      case value(component, "RECURRENCE-ID") do
        nil -> periods(component, range, floating, overrides)
        _override -> periods(component, range, floating, [])
      end
    end)
  end

  @doc """
  Write a `VFREEBUSY` for a set of busy periods.

  ### Arguments

  * `periods` is a list of `{fbtype, {from, to}}` pairs.

  * `range` is the `{start, finish}` the report covers.

  ### Options

  * `:events` is a list of components to carry inside the calendar
    beside the `VFREEBUSY` — an extended answer's events.

  * `:attendee` names the calendar user the report is about, for a
    scheduling response.

  * `:organizer` names the calendar user who asked.

  * `:method` names the iTIP method the object carries. A scheduling
    response is a `REPLY`; the free-busy *report* of RFC 4791 section
    7.10 is not a scheduling message and carries none.

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
      ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Dav//CalDAV//EN"] ++
        bound("METHOD", Keyword.get(options, :method)) ++
        ["BEGIN:VFREEBUSY"] ++
        bound("DTSTART", from) ++
        bound("DTEND", to) ++
        bound("ORGANIZER", Keyword.get(options, :organizer)) ++
        bound("ATTENDEE", Keyword.get(options, :attendee)) ++
        ["DTSTAMP:" <> stamp()] ++
        Enum.map(periods, &freebusy/1) ++
        ["END:VFREEBUSY", "END:VCALENDAR"]

    folded = Enum.map(lines, &[ICalendar.fold(&1), "\r\n"])

    IO.iodata_to_binary([
      Enum.drop(folded, -1),
      Enum.map(Keyword.get(options, :events, []), &ICalendar.write/1),
      List.last(folded)
    ])
  end

  defp bound(_name, nil), do: []

  # A calendar user is named the same way the request named them. The
  # `CN` a client sent is what it will look for in the answer, and
  # dropping it leaves the client with an address and no name to show.
  defp bound(name, {value, parameters}) when is_map(parameters) do
    written =
      Enum.map_join(parameters, fn {parameter, setting} -> ";#{parameter}=#{setting}" end)

    [name <> written <> ":" <> value]
  end

  defp bound(name, value), do: [name <> ":" <> value]

  defp freebusy({type, bounds}) do
    "FREEBUSY;FBTYPE=" <> type <> ":" <> Enum.map_join(bounds, ",", &period(&1, type))
  end

  # RFC 5545 section 3.3.9 allows a period to be written as two
  # instants or as a start and a duration, and each specification
  # writes its own busy types the way its own examples do: RFC 5546
  # section 3.3.2 states busy time as a start and a duration, while
  # RFC 7953 section 5 states unavailable time as two instants.
  #
  # The difference is not cosmetic. A busy period is something that
  # *lasts* — a meeting of an hour — and the duration is what the
  # organiser agreed to. An unavailable period is the gap between two
  # moments a rule produced, and its ends are the meaningful part.
  defp period(bounds, type) when type in @bounded do
    {began, ended} = bounds

    utc(began) <> "/" <> utc(ended)
  end

  defp period({began, ended}, _type) do
    case elapsed(began, ended) do
      {:ok, total} -> utc(began) <> "/" <> lasting(total)
      :error -> utc(began) <> "/" <> utc(ended)
    end
  end

  defp elapsed(began, ended) do
    with {:ok, from} <- Tempo.to_elixir(began),
         {:ok, to} <- Tempo.to_elixir(ended),
         from when not is_nil(from) <- seconds(from),
         to when not is_nil(to) <- seconds(to) do
      {:ok, to - from}
    else
      _unconvertible -> :error
    end
  end

  defp seconds(%Date{} = date), do: seconds(NaiveDateTime.new!(date, ~T[00:00:00]))
  defp seconds(%DateTime{} = moment), do: DateTime.to_unix(moment)
  defp seconds(%NaiveDateTime{} = naive), do: NaiveDateTime.diff(naive, ~N[1970-01-01 00:00:00])
  defp seconds(_other), do: nil

  defp lasting(total) when total <= 0, do: "PT0S"

  defp lasting(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    date = if days > 0, do: "#{days}D", else: ""

    time =
      [{hours, "H"}, {minutes, "M"}, {seconds, "S"}]
      |> Enum.reject(fn {amount, _unit} -> amount == 0 end)
      |> Enum.map_join(fn {amount, unit} -> "#{amount}#{unit}" end)

    if time == "", do: "P" <> date, else: "P" <> date <> "T" <> time
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  # iCalendar wants the *basic* ISO 8601 form — `20260615T090000Z`,
  # not `2026-06-15T09:00:00Z` — which is why this does not go through
  # Tempo's own `to_iso8601/1`, whose output is Tempo's notation.
  #
  # `Tempo.to_elixir/1` chooses the native type the value actually is
  # rather than being told one, and shifts an offset to UTC on the way
  # (`09:00+10:00` becomes `23:00Z` the day before), which is exactly
  # what stamping the result with `Z` then claims.
  defp utc(moment) do
    case Tempo.to_elixir(moment) do
      {:ok, %Date{} = date} -> Calendar.strftime(date, "%Y%m%dT000000Z")
      {:ok, native} -> Calendar.strftime(native, "%Y%m%dT%H%M%SZ")
      _unconvertible -> inspect(moment)
    end
  end

  defp local?(%{name: {_namespace, local}}, local), do: true
  defp local?(_element, _local), do: false
end
