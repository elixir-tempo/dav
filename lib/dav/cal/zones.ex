defmodule Dav.Cal.Zones do
  @moduledoc """
  The time zone catalogue, and the observances of a zone over a period.

  RFC 7808 serves time zone data: which zones exist, what a client may
  call them, and when each one changes its offset. The zones themselves
  come from IANA, through the `tz` dependency — this module reads the
  same distribution `tz` compiles against, so the catalogue and the
  offsets can never describe different releases of the database.

  The catalogue is read once, at compile time, and the parsing is
  trivial: IANA's files name a zone with `Zone <tzid>` and an alternate
  name for one with `Link <tzid> <alias>`. A zone is named canonically
  by its `Zone` line, and everything else is an alias that resolves to
  it — `US/Eastern` and `GB` are not zones but other names for
  `America/New_York` and `Europe/London`.

  """

  alias Dav.Cal.ICalendar
  alias Tz.PeriodsProvider

  @version Tz.iana_version()
  @directory Path.join(Tz.IanaDataDir.dir(), "tzdata" <> @version)

  # `backward` holds the aliases retained for compatibility, which is
  # where `US/Eastern` and `GB` live. Leaving it out would answer
  # `tzid-not-found` for names clients have used for thirty years.
  @files ~w(africa antarctica asia australasia backward etcetera europe northamerica southamerica)

  for file <- @files do
    @external_resource Path.join(@directory, file)
  end

  @lines Enum.flat_map(@files, fn file ->
           @directory |> Path.join(file) |> File.read!() |> String.split("\n")
         end)

  @zones for("Zone" <> rest <- @lines, do: rest |> String.split() |> hd()) |> Enum.sort()

  @links for "Link" <> rest <- @lines,
             [zone, alias_name | _rest] = String.split(rest),
             do: {zone, alias_name}

  @aliases @links
           |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
           |> Map.new(fn {zone, named} -> {zone, Enum.sort(named)} end)

  @canonical Map.new(@links, fn {zone, alias_name} -> {alias_name, zone} end)

  @typedoc "A zone, and every other name a client may call it by."
  @type entry :: {tzid :: String.t(), aliases :: [String.t()]}

  @typedoc """
  One stretch of unchanging offset: the abbreviation in force, the
  instant it began as a UTC `DateTime`, and the offsets in seconds
  either side of that instant.
  """
  @type observance :: %{
          name: String.t(),
          onset: DateTime.t(),
          from: integer(),
          to: integer()
        }

  @doc """
  The IANA release this catalogue describes.

  ### Returns

  * The version as IANA names it, such as `"2024a"`.

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Every zone, with its aliases.

  ### Returns

  * A list of `{tzid, aliases}` in tzid order. A zone with no other
    name carries an empty alias list.

  ### Examples

      iex> Dav.Cal.Zones.list() |> List.keyfind("America/New_York", 0) |> elem(0)
      "America/New_York"

  """
  @spec list() :: [entry()]
  def list, do: Enum.map(@zones, &{&1, Map.get(@aliases, &1, [])})

  @doc """
  Resolves a name to the zone it names.

  ### Arguments

  * `name` is a tzid or an alias of one.

  ### Returns

  * The canonical tzid, or `nil` when nothing goes by that name.

  ### Examples

      iex> Dav.Cal.Zones.canonical("US/Eastern")
      "America/New_York"

      iex> Dav.Cal.Zones.canonical("Europe/London")
      "Europe/London"

      iex> Dav.Cal.Zones.canonical("Mars/Olympus_Mons")
      nil

  """
  @spec canonical(String.t()) :: String.t() | nil
  def canonical(name) when is_binary(name) do
    if name in @zones, do: name, else: Map.get(@canonical, name)
  end

  @doc """
  Every zone whose name, or one of whose aliases, matches a pattern.

  `*` stands for any run of characters. Matching ignores case, and
  treats a space as the underscore IANA writes it with, so a client
  searching for `*New York*` finds `America/New_York`. A pattern that
  is nothing but wildcards is refused rather than answered with the
  whole catalogue.

  ### Arguments

  * `pattern` is the name to look for, with `*` where anything may
    stand.

  ### Returns

  * `{:ok, entries}` with the matching `{tzid, aliases}` in tzid
    order, empty when nothing matches.

  * `{:error, :invalid_pattern}` when the pattern selects everything.

  ### Examples

      iex> {:ok, found} = Dav.Cal.Zones.find("US/East*")
      iex> Enum.map(found, &elem(&1, 0))
      ["America/New_York"]

      iex> Dav.Cal.Zones.find("**")
      {:error, :invalid_pattern}

  """
  @spec find(String.t()) :: {:ok, [entry()]} | {:error, :invalid_pattern}
  def find(pattern) when is_binary(pattern) do
    if String.replace(pattern, "*", "") == "" do
      {:error, :invalid_pattern}
    else
      {:ok, Enum.filter(list(), fn {tzid, aliases} -> matches?([tzid | aliases], pattern) end)}
    end
  end

  defp matches?(names, pattern) do
    expression =
      pattern
      |> normalise()
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    {:ok, regex} = Regex.compile("^" <> expression <> "$")

    Enum.any?(names, &Regex.match?(regex, normalise(&1)))
  end

  # A space and an underscore are the same character to a searcher,
  # and case is not a distinction IANA makes between two zones.
  defp normalise(name), do: name |> String.downcase() |> String.replace("_", " ")

  @doc """
  The observances of a zone across a period.

  The first observance is always the period in force when the window
  opens, reported at the opening instant with the same offset either
  side of it — a client asking what the offset is on 1 January is
  answered even by a zone that has not changed offset in fifty years.
  Every later observance is a transition: the instant the offset
  changed, and the offsets before and after.

  ### Arguments

  * `name` is a tzid or an alias of one.

  * `from` is the instant the window opens.

  * `until` is the instant it closes, and is not itself included.

  ### Returns

  * `{:ok, observances}` in onset order.

  * `{:error, :not_found}` when nothing goes by that name.

  ### Examples

      iex> {:ok, [first | _rest]} = Dav.Cal.Zones.observances("America/Phoenix", ~U[2006-01-01 00:00:00Z], ~U[2007-01-01 00:00:00Z])
      iex> {first.name, first.from, first.to}
      {"MST", -25200, -25200}

  """
  @spec observances(String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [observance()]} | {:error, :not_found}
  def observances(name, %DateTime{} = from, %DateTime{} = until) do
    with tzid when is_binary(tzid) <- canonical(name),
         {:ok, periods} <- PeriodsProvider.periods(tzid) do
      opening = seconds(from)
      closing = seconds(until)

      changes =
        for {at, started, ended, _rule} <- periods,
            is_integer(at),
            at >= opening,
            at < closing,
            do: %{
              name: abbreviation(started),
              onset: instant(at),
              from: offset(ended),
              to: offset(started)
            }

      {:ok, [in_force(periods, opening) | Enum.sort_by(changes, & &1.onset, DateTime)]}
    else
      _absent -> {:error, :not_found}
    end
  end

  # The period covering an instant is the latest one that had begun by
  # then, which the descending order makes the first match.
  defp in_force(periods, opening) do
    {_at, started, _ended, _rule} =
      Enum.find(periods, fn {at, _started, _ended, _rule} -> at == :min or at <= opening end)

    %{
      name: abbreviation(started),
      onset: instant(opening),
      from: offset(started),
      to: offset(started)
    }
  end

  defp abbreviation({_utc, _standard, name}), do: name

  # An observance reports the whole offset from UTC, which is the
  # zone's own offset plus whatever daylight saving is adding to it.
  defp offset({utc, standard, _name}), do: utc + standard

  defp seconds(%DateTime{} = moment) do
    :calendar.datetime_to_gregorian_seconds({
      {moment.year, moment.month, moment.day},
      {moment.hour, moment.minute, moment.second}
    })
  end

  defp instant(seconds) do
    {date, time} = :calendar.gregorian_seconds_to_datetime(seconds)
    {:ok, moment} = NaiveDateTime.from_erl({date, time})
    DateTime.from_naive!(moment, "Etc/UTC")
  end

  @doc """
  A zone's definition, as an iCalendar `VTIMEZONE` component.

  Every offset change IANA records becomes an observance. Changes that
  say the same thing — the same name, the same offset either side —
  are gathered into one sub-component carrying an `RDATE` for each,
  which is how a zone with a century of irregular history stays
  readable. The definition is named by the name that was asked for, so
  a client that knows the zone as `GB` is given `TZID:GB` and need not
  learn that IANA files it under `Europe/London`.

  ### Arguments

  * `name` is a tzid or an alias of one.

  ### Returns

  * `{:ok, component}` holding a `VCALENDAR` wrapping the `VTIMEZONE`,
    ready for `Dav.Cal.ICalendar.write/1`.

  * `{:error, :not_found}` when nothing goes by that name.

  ### Examples

      iex> {:ok, calendar} = Dav.Cal.Zones.definition("GB")
      iex> [zone] = calendar.components
      iex> Enum.find(zone.properties, &(&1.name == "TZID")).value
      "GB"

  """
  @spec definition(String.t()) :: {:ok, ICalendar.component()} | {:error, :not_found}
  def definition(name) do
    with tzid when is_binary(tzid) <- canonical(name),
         {:ok, periods} <- PeriodsProvider.periods(tzid) do
      {:ok,
       %{
         name: "VCALENDAR",
         properties: [
           property("VERSION", "2.0"),
           property("PRODID", "-//kipcole9//dav//EN"),
           property("CALSCALE", "GREGORIAN")
         ],
         components: [
           %{
             name: "VTIMEZONE",
             properties: [property("TZID", name), property("X-LIC-LOCATION", name)],
             components: observed(periods)
           }
         ]
       }}
    else
      _absent -> {:error, :not_found}
    end
  end

  defp observed(periods) do
    periods
    |> Enum.filter(fn {at, _started, ended, _rule} -> is_integer(at) and ended != nil end)
    |> Enum.group_by(fn {_at, started, ended, _rule} -> {started, ended} end, &elem(&1, 0))
    |> Enum.map(fn {{started, ended}, onsets} ->
      transition(started, ended, Enum.sort(onsets))
    end)
    |> Enum.sort_by(& &1.onset)
    |> Enum.map(& &1.component)
  end

  defp transition({_utc, standard, name} = started, ended, [first | _rest] = onsets) do
    local = &local_time(&1 + offset(ended))

    component = %{
      name: if(standard == 0, do: "STANDARD", else: "DAYLIGHT"),
      properties:
        [property("DTSTART", local.(first))] ++
          Enum.map(onsets, &property("RDATE", local.(&1))) ++
          [
            property("TZNAME", name),
            property("TZOFFSETFROM", written(offset(ended))),
            property("TZOFFSETTO", written(offset(started)))
          ],
      components: []
    }

    %{onset: first, component: component}
  end

  defp property(name, value), do: %{name: name, parameters: %{}, value: value}

  defp local_time(seconds) do
    {{year, month, day}, {hour, minute, second}} =
      :calendar.gregorian_seconds_to_datetime(seconds)

    :io_lib.format(~c"~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end

  # RFC 5545 writes an offset as hours and minutes, and only as hours,
  # minutes and seconds where a zone's local mean time needs them —
  # which the nineteenth century routinely does.
  defp written(offset) do
    sign = if offset < 0, do: "-", else: "+"
    total = abs(offset)
    {hours, minutes, seconds} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}

    parts =
      if seconds == 0,
        do: :io_lib.format(~c"~2..0B~2..0B", [hours, minutes]),
        else: :io_lib.format(~c"~2..0B~2..0B~2..0B", [hours, minutes, seconds])

    sign <> IO.iodata_to_binary(parts)
  end
end
