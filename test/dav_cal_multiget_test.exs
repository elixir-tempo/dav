defmodule Dav.Cal.MultigetTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Dav.Cal
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Dav.Xml

  @multiget {Xml.caldav(), "calendar-multiget"}

  setup do
    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["home"], collection?: true, types: [Cal.calendar()]}
      ])

    options =
      DavPlug.init(store: WritableStore, context: agent, reports: [{@multiget, Dav.Cal.Multiget}])

    for {name, summary} <- [{"1.ics", "One"}, {"2.ics", "Two"}] do
      data =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:#{name}",
            "SUMMARY:#{summary}",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      DavPlug.call(conn("PUT", "/home/#{name}", data), options)
    end

    %{options: options}
  end

  defp multiget(hrefs, props, options) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop>#{props}</D:prop>
      #{Enum.map_join(hrefs, "", &"<D:href>#{&1}</D:href>")}
    </C:calendar-multiget>
    """

    DavPlug.call(conn("REPORT", "/home", body), options)
  end

  test "returns exactly the objects named", context do
    conn = multiget(["/home/1.ics"], "<D:getetag/>", context.options)

    assert conn.status == 207
    assert conn.resp_body =~ "/home/1.ics"
    refute conn.resp_body =~ "/home/2.ics"
  end

  test "calendar-data returns each object's own body", context do
    conn =
      multiget(["/home/1.ics", "/home/2.ics"], "<C:calendar-data/>", context.options)

    assert conn.resp_body =~ "SUMMARY:One"
    assert conn.resp_body =~ "SUMMARY:Two"
  end

  test "an href that is not there gets a response of its own, not silence", context do
    # A client asking for three and receiving two cannot tell which it
    # lost, so the missing one is named with its own 404.
    conn =
      multiget(["/home/1.ics", "/home/gone.ics", "/home/2.ics"], "<D:getetag/>", context.options)

    assert conn.status == 207
    assert conn.resp_body =~ "/home/gone.ics"
    assert conn.resp_body =~ "HTTP/1.1 404 Not Found"
    # Three responses, not two.
    assert conn.resp_body |> String.split("<D:response>") |> length() == 4
  end

  test "Depth is ignored, as the specification requires", context do
    with_depth =
      conn("REPORT", "/home", multiget_body(["/home/1.ics"]))
      |> put_req_header("depth", "1")
      |> DavPlug.call(context.options)

    without = multiget(["/home/1.ics"], "<D:getetag/>", context.options)

    assert with_depth.status == 207
    assert with_depth.resp_body == without.resp_body
  end

  defp multiget_body(hrefs) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <C:calendar-multiget xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:prop><D:getetag/></D:prop>
      #{Enum.map_join(hrefs, "", &"<D:href>#{&1}</D:href>")}
    </C:calendar-multiget>
    """
  end

  test "the report is advertised alongside the others", context do
    body =
      ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:supported-report-set/></D:prop></D:propfind>)

    conn =
      conn("PROPFIND", "/home", body)
      |> put_req_header("depth", "0")
      |> DavPlug.call(context.options)

    assert conn.resp_body =~ "<C:calendar-multiget/>"
  end
end
