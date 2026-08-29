defmodule Dav.Cal.QueryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Dav.Cal
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn

  @query {Xml.caldav(), "calendar-query"}

  setup do
    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["home"], collection?: true, types: [Cal.calendar()]}
      ])

    options =
      DavPlug.init(store: WritableStore, context: agent, reports: [{@query, Dav.Cal.Query}])

    put = fn name, lines ->
      data =
        (["BEGIN:VCALENDAR", "BEGIN:VEVENT"] ++ lines ++ ["END:VEVENT", "END:VCALENDAR"])
        |> Enum.join("\r\n")
        |> Kernel.<>("\r\n")

      DavPlug.call(conn("PUT", "/home/#{name}", data), options)
    end

    put.("june.ics", [
      "UID:1",
      "SUMMARY:Team lunch",
      "DTSTART:20260615T090000Z",
      "DTEND:20260615T100000Z"
    ])

    put.("july.ics", [
      "UID:2",
      "SUMMARY:Retro",
      "DTSTART:20260715T090000Z",
      "DTEND:20260715T100000Z"
    ])

    put.("weekly.ics", [
      "UID:3",
      "SUMMARY:Standup",
      "DTSTART:20260601T090000Z",
      "DTEND:20260601T093000Z",
      "RRULE:FREQ=WEEKLY;COUNT=8"
    ])

    %{options: options}
  end

  defp query(inner, options) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      #{inner}
    </C:calendar-query>
    """

    # A REPORT without a Depth header means Depth 0, which searches
    # the collection itself and not its members. Real clients send it.
    conn("REPORT", "/home", body)
    |> Conn.put_req_header("depth", "1")
    |> DavPlug.call(options)
  end

  @june ~s(<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260601T000000Z" end="20260701T000000Z"/></C:comp-filter></C:comp-filter></C:filter>)

  describe "the whole path, request to result" do
    test "returns only the objects in the window", context do
      conn = query(~s(<D:prop><D:getetag/></D:prop>) <> @june, context.options)

      assert conn.status == 207
      assert conn.resp_body =~ "/home/june.ics"
      refute conn.resp_body =~ "/home/july.ics"
    end

    test "a recurring event matches through an instance, not only its first", context do
      # Standup starts 1 June and recurs weekly; the window below
      # contains only its third occurrence.
      mid_june =
        ~s(<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:time-range start="20260615T000000Z" end="20260616T000000Z"/></C:comp-filter></C:comp-filter></C:filter>)

      conn = query(~s(<D:prop><D:getetag/></D:prop>) <> mid_june, context.options)

      assert conn.resp_body =~ "/home/weekly.ics"
    end

    test "calendar-data returns the object itself", context do
      conn = query(~s(<D:prop><C:calendar-data/></D:prop>) <> @june, context.options)

      assert conn.resp_body =~ "BEGIN:VEVENT"
      assert conn.resp_body =~ "Team lunch"
      # Escaped into the XML rather than breaking it.
      refute conn.resp_body =~ "<BEGIN"
    end

    test "a property the object does not have comes back as 404, not missing", context do
      conn =
        query(
          ~s(<D:prop><D:getetag/><D:invented-by-a-client/></D:prop>) <> @june,
          context.options
        )

      assert conn.resp_body =~ "HTTP/1.1 404 Not Found"
      assert conn.resp_body =~ "HTTP/1.1 200 OK"
    end

    test "a text filter selects on the calendar data", context do
      by_summary =
        ~s(<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="SUMMARY"><C:text-match>retro</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter></C:filter>)

      conn = query(~s(<D:prop><D:getetag/></D:prop>) <> by_summary, context.options)

      assert conn.resp_body =~ "/home/july.ics"
      refute conn.resp_body =~ "/home/june.ics"
    end

    test "a filter matching nothing is an empty multistatus, not an error", context do
      nothing =
        ~s(<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter></C:filter>)

      conn = query(~s(<D:prop><D:getetag/></D:prop>) <> nothing, context.options)

      assert conn.status == 207
      refute conn.resp_body =~ "<D:response>"
    end

    test "a body with no filter is malformed", context do
      conn = query(~s(<D:prop><D:getetag/></D:prop>), context.options)

      assert conn.status == 400
    end
  end

  describe "discovery" do
    test "the report is advertised so a client can find it", context do
      body =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:supported-report-set/></D:prop></D:propfind>)

      conn =
        conn("PROPFIND", "/home", body)
        |> put_req_header("depth", "0")
        |> DavPlug.call(context.options)

      assert conn.resp_body =~ "<C:calendar-query/>"
      assert conn.resp_body =~ ~s(xmlns:C="urn:ietf:params:xml:ns:caldav")
    end
  end
end
