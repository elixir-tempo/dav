defmodule Dav.Cal.TimezoneService do
  @moduledoc """
  RFC 7808: a time zone data distribution service.

  A calendar entry is a local time and the name of a zone, which is
  only meaningful to a client holding the same definition of that zone
  as the server. RFC 7808 is how a client gets one: it asks which
  zones exist, then for the definition of the ones it needs, and it
  asks the same server its events are on rather than shipping a copy
  of the IANA database that begins going stale the day it is built.

  This is a `Plug`, not part of the DAV plug, because it is not DAV —
  no properties, no methods beyond `GET`, no resources. Mount it where
  the deployment likes and tell the DAV plug where it went, so that
  `CALDAV:timezone-service-set` can point at it:

      forward "/timezones", to: Dav.Cal.TimezoneService

  Four actions are served, addressed by path: `/capabilities` says
  what this service does, `/zones` lists or searches the catalogue,
  `/zones/{tzid}` returns one definition as iCalendar, and
  `/observances/{tzid}` expands a zone's offset changes across a
  window without the client having to interpret a recurrence rule.

  The zones themselves come from `Dav.Cal.Zones`.

  """

  @behaviour Plug

  import Plug.Conn

  alias Dav.Cal.ICalendar
  alias Dav.Cal.Zones

  @publisher "urn:ietf:params:tzdata"

  # The actions this service implements, in the shape
  # `/capabilities` reports them. RFC 7808 lets a client discover
  # which of them a server has, so the list is the answer to that
  # question and the routing table both.
  @actions [
    {"capabilities", []},
    {"list", ["changedsince"]},
    {"get", ["tzid", "start", "end"]},
    {"expand", ["tzid", "start", "end"]},
    {"find", ["pattern"]}
  ]

  @impl Plug
  def init(options), do: %{at: Keyword.get(options, :at, [])}

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, %{at: at}) do
    case Enum.drop(conn.path_info, length(at)) do
      ["capabilities"] -> answered(conn, capabilities())
      ["zones"] -> catalogue(conn)
      ["zones", tzid] -> definition(conn, tzid)
      ["zones", tzid, ""] -> definition(conn, tzid)
      ["observances", tzid] -> expansion(conn, tzid)
      ["observances", tzid, ""] -> expansion(conn, tzid)
      _unknown -> refused(conn, 400, "invalid-action", "no such action")
    end
  end

  # Everything else is a read-only service saying so. A client that
  # tries to write here has misunderstood what this is, and `405` with
  # an `Allow` header is the answer that tells it which.
  def call(%Plug.Conn{} = conn, _options) do
    conn |> put_resp_header("allow", "GET") |> send_resp(405, "")
  end

  defp capabilities do
    %{
      "version" => 1,
      "info" => %{
        "primary-source" => "IANA " <> Zones.version(),
        "formats" => ["text/calendar"],
        "contacts" => []
      },
      "actions" =>
        Enum.map(@actions, fn {name, parameters} ->
          %{
            "name" => name,
            "parameters" => Enum.map(parameters, &%{"name" => &1, "required" => false})
          }
        end)
    }
  end

  # `/zones` with no pattern lists everything; with one it searches.
  # Two patterns is not a narrower search but a contradiction, and is
  # refused rather than guessed at.
  defp catalogue(conn) do
    case singular(conn, "pattern") do
      :absent ->
        answered(conn, %{"dtstamp" => stamped(), "timezones" => Enum.map(Zones.list(), &named/1)})

      {:ok, pattern} ->
        case Zones.find(pattern) do
          {:ok, found} ->
            answered(conn, %{"dtstamp" => stamped(), "timezones" => Enum.map(found, &named/1)})

          {:error, :invalid_pattern} ->
            refused(conn, 400, "invalid-pattern", "the pattern matches every zone")
        end

      :repeated ->
        refused(conn, 400, "invalid-pattern", "one pattern at a time")
    end
  end

  defp named({tzid, aliases}) do
    %{
      "tzid" => tzid,
      "etag" => Zones.version(),
      "last-modified" => stamped(),
      "publisher" => @publisher,
      "aliases" => aliases
    }
  end

  defp stamped, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # A parameter given once is a value, given twice is a mistake, and
  # given not at all is the caller's business to interpret — `start`
  # is required where `pattern` is not.
  # Read from the query string rather than from decoded parameters,
  # which keep one value per name: a request that gives `start` twice
  # is a request this service refuses, and a decoder that quietly
  # drops one of them takes that decision away.
  defp singular(conn, name) do
    case for {given, value} <- URI.query_decoder(conn.query_string), given == name, do: value do
      [] -> :absent
      [value] when is_binary(value) -> {:ok, value}
      _repeated -> :repeated
    end
  end

  defp answered(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, :json.encode(body))
  end

  defp refused(conn, status, code, description) do
    body = %{"error-code" => code, "description" => description}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, :json.encode(body))
  end

  # A definition is asked for by whatever name the client knows, and
  # is given back under that name — a client that stores `TZID=GB` on
  # its events needs a `VTIMEZONE` its own events refer to.
  defp definition(conn, tzid) do
    case Zones.definition(URI.decode(tzid)) do
      {:ok, calendar} ->
        conn
        |> put_resp_content_type("text/calendar")
        |> send_resp(200, ICalendar.write(calendar))

      {:error, :not_found} ->
        refused(conn, 404, "tzid-not-found", "no zone goes by that name")
    end
  end

  # The window is required, in full, and closed: a client asking for
  # observances without saying which is not making a smaller request
  # but an unbounded one, and a window that ends before it opens
  # describes nothing at all.
  defp expansion(conn, tzid) do
    with {:zone, zone} when is_binary(zone) <- {:zone, Zones.canonical(URI.decode(tzid))},
         {:start, {:ok, from}} <- {:start, moment(conn, "start")},
         {:end, {:ok, until}} <- {:end, moment(conn, "end")},
         {:window, true} <- {:window, DateTime.after?(until, from)},
         {:ok, observances} <- Zones.observances(zone, from, until) do
      answered(conn, %{
        "dtstamp" => stamped(),
        "tzid" => zone,
        "observances" => Enum.map(observances, &expanded/1)
      })
    else
      {:zone, _absent} ->
        refused(conn, 404, "tzid-not-found", "no zone goes by that name")

      {:start, _bad} ->
        refused(conn, 400, "invalid-start", "start must be one UTC date-time")

      _end_or_window ->
        refused(conn, 400, "invalid-end", "end must be one UTC date-time after start")
    end
  end

  defp expanded(observance) do
    %{
      "name" => observance.name,
      "onset" => DateTime.to_iso8601(observance.onset),
      "utc-offset-from" => observance.from,
      "utc-offset-to" => observance.to
    }
  end

  # RFC 7808 dates the window in the extended form with an explicit
  # zone. A truncated `2009`, or a basic `20090101`, is not a date
  # this service guesses the rest of.
  defp moment(conn, name) do
    with {:ok, given} <- singular(conn, name),
         {:ok, moment, 0} <- DateTime.from_iso8601(given) do
      {:ok, moment}
    else
      _absent_or_malformed -> :error
    end
  end
end
