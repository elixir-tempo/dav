defmodule Dav.Cal.TimezoneQuery do
  @moduledoc """
  CalendarServer's time zone query service, the ancestor of RFC 7808.

  Apple's servers answered for time zones before RFC 7808 settled the
  question, and their clients still ask this way: one resource taking
  a `method` parameter on a `GET` or a `POST`, rather than the paths
  and JSON of `Dav.Cal.TimezoneService`. Three methods are served —
  `list` names the catalogue, `get` returns one zone as iCalendar, and
  `expand` reports a zone's offset changes across a window.

  The differences from RFC 7808 are the interesting part, because they
  are what a client written against one and pointed at the other will
  trip on. Dates here are written in the basic calendar form,
  `20080101`, and are *local* to the zone being asked about rather
  than UTC. Observances are reported in that local time too, with
  offsets spelled the way iCalendar spells them, `-0500`. Failures are
  DAV `error` documents naming a condition, not JSON error codes.

  Both services read the same catalogue, `Dav.Cal.Zones`, so the two
  never disagree about a zone. Mount this one where the deployment's
  clients expect to find it:

      forward "/timezones", to: Dav.Cal.TimezoneQuery

  """

  @behaviour Plug

  import Plug.Conn

  alias Dav.Cal.ICalendar
  alias Dav.Cal.Zones
  alias Dav.Xml

  @namespace "http://calendarserver.org/ns/"

  # The service's own vocabulary of failures. Each is a condition in
  # CalendarServer's namespace, which is what a client of this service
  # matches on — the status code alone does not say which parameter
  # was wrong.
  @conditions %{
    method: {@namespace, "supported-method"},
    repeated: {@namespace, "valid-method"},
    tzid: {@namespace, "valid-timezone"},
    unknown: {@namespace, "timezone-available"},
    start: {@namespace, "valid-start-date"},
    end: {@namespace, "valid-end-date"}
  }

  @impl Plug
  def init(options), do: Map.new(options)

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _options) when method in ["GET", "POST"] do
    case singular(conn, "method") do
      # No query at all is a client asking what is here, which is the
      # catalogue. A query that names other parameters but not
      # `method` is a client asking for something this service does
      # not do, and saying so is more use than a listing it did not
      # ask for.
      :absent when conn.query_string == "" -> catalogue(conn)
      :absent -> refused(conn, 400, :method)
      {:ok, "list"} -> catalogue(conn)
      {:ok, "get"} -> definition(conn)
      {:ok, "expand"} -> expansion(conn)
      {:ok, _unknown} -> refused(conn, 400, :method)
      :repeated -> refused(conn, 400, :repeated)
    end
  end

  # The resource exists, so a client may ask about it — which is the
  # whole of what `PROPFIND` gets here, there being no properties on a
  # service that holds nothing.
  def call(%Plug.Conn{method: "PROPFIND"} = conn, _options) do
    {:ok, _body, conn} = read_body(conn)
    row = {conn.request_path, [{"HTTP/1.1 200 OK", [{{Xml.dav(), "resourcetype"}, nil}]}]}

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(207, Xml.multistatus([row]))
  end

  # Writing to a query service is a category error, and `403` with the
  # condition names it as one.
  def call(%Plug.Conn{} = conn, _options) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error(@conditions.method))
  end

  defp refused(conn, status, condition) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(status, Xml.error(Map.fetch!(@conditions, condition)))
  end

  # Read from the query string rather than from decoded parameters,
  # which keep one value per name: naming `method` or `tzid` twice is
  # a request this service refuses rather than one it picks from.
  defp singular(conn, name) do
    case for {given, value} <- URI.query_decoder(conn.query_string), given == name, do: value do
      [] -> :absent
      [value] when is_binary(value) -> {:ok, value}
      _repeated -> :repeated
    end
  end

  # The catalogue, named rather than described: a client asks for the
  # definitions it does not already hold, so the list is tzids and the
  # other names they answer to.
  defp catalogue(conn) do
    zones =
      for {tzid, aliases} <- Zones.list() do
        [
          "<timezone><tzid>",
          Xml.escape(tzid),
          "</tzid>",
          Enum.map(aliases, &["<alias>", Xml.escape(&1), "</alias>"]),
          "</timezone>"
        ]
      end

    answered(conn, ["<dtstamp>", stamped(), "</dtstamp>", zones])
  end

  defp definition(conn) do
    with {:ok, name} <- named(conn),
         {:ok, calendar} <- Zones.definition(name) do
      conn
      |> put_resp_content_type("text/calendar")
      |> send_resp(200, ICalendar.write(calendar))
    else
      {:error, :not_found} -> refused(conn, 404, :unknown)
      _unnamed -> refused(conn, 400, :tzid)
    end
  end

  defp expansion(conn) do
    with {:ok, name} <- named(conn),
         zone when is_binary(zone) <- Zones.canonical(name),
         {:start, {:ok, from}} <- {:start, moment(conn, "start", zone)},
         {:end, {:ok, until}} <- {:end, moment(conn, "end", zone)},
         {:end, true} <- {:end, DateTime.after?(until, from)},
         {:ok, observances} <- Zones.observances(zone, from, until) do
      answered(conn, [
        "<dtstamp>",
        stamped(),
        "</dtstamp><tzdata><tzid>",
        Xml.escape(zone),
        "</tzid>",
        Enum.map(observances, &expanded/1),
        "</tzdata>"
      ])
    else
      nil -> refused(conn, 404, :unknown)
      {:start, _bad} -> refused(conn, 400, :start)
      {:end, _bad} -> refused(conn, 400, :end)
      _unnamed -> refused(conn, 400, :tzid)
    end
  end

  defp expanded(observance) do
    [
      "<observance><name>",
      Xml.escape(observance.name),
      "</name><onset>",
      Zones.local_form(observance.onset, observance.from),
      "</onset><utc-offset-from>",
      Zones.offset_form(observance.from),
      "</utc-offset-from><utc-offset-to>",
      Zones.offset_form(observance.to),
      "</utc-offset-to></observance>"
    ]
  end

  defp named(conn) do
    case singular(conn, "tzid") do
      {:ok, tzid} -> {:ok, URI.decode(tzid)}
      _absent_or_repeated -> :error
    end
  end

  # A date here is basic and local: `20080101` means midnight that
  # morning *in the zone being asked about*, which is the reading a
  # client gets when it asks what its own next year looks like. The
  # offset in force at that moment is what turns it into an instant,
  # and the offset is itself a fact about the zone — so the naive
  # reading is taken first and then corrected by what it finds.
  defp moment(conn, name, zone) do
    with {:ok, given} <- singular(conn, name),
         <<year::binary-4, month::binary-2, day::binary-2>> <- given,
         {:ok, date} <- Date.from_iso8601(year <> "-" <> month <> "-" <> day) do
      naive = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {:ok, DateTime.add(naive, -in_force(zone, naive), :second)}
    else
      _absent_or_malformed -> :error
    end
  end

  defp in_force(zone, moment) do
    case Zones.observances(zone, moment, DateTime.add(moment, 1, :second)) do
      {:ok, [%{to: offset} | _rest]} -> offset
      _absent -> 0
    end
  end

  defp answered(conn, inner) do
    document = [
      ~s(<?xml version="1.0" encoding="utf-8"?><timezones xmlns="),
      @namespace,
      ~s(">),
      inner,
      "</timezones>"
    ]

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(200, document)
  end

  defp stamped, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
