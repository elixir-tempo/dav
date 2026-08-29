defmodule Dav.Cal.FreeBusyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn

  @free_busy {Xml.caldav(), "free-busy-query"}

  setup do
    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["home"], collection?: true, types: [Cal.calendar()]}
      ])

    options =
      DavPlug.init(
        store: WritableStore,
        context: agent,
        reports: [{@free_busy, Dav.Cal.FreeBusy}]
      )

    %{options: options, agent: agent}
  end

  defp event(options, name, properties) do
    data =
      Enum.join(
        ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:#{name}"] ++
          properties ++ ["END:VEVENT", "END:VCALENDAR"],
        "\r\n"
      ) <> "\r\n"

    DavPlug.call(conn("PUT", "/home/#{name}", data), options)
  end

  defp query(
         options,
         path \\ "/home",
         range \\ ~s(start="20260601T000000Z" end="20260701T000000Z")
       ) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <C:free-busy-query xmlns:C="urn:ietf:params:xml:ns:caldav">
      <C:time-range #{range}/>
    </C:free-busy-query>
    """

    DavPlug.call(conn("REPORT", path, body), options)
  end

  # A reader unfolds before matching; so must a test, or an assertion
  # silently depends on where the 75-octet boundary happens to fall.
  defp unfolded(conn), do: String.replace(conn.resp_body, "\r\n ", "")

  test "answers with an iCalendar object, not a multistatus", context do
    event(context.options, "1.ics", ["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"])

    conn = query(context.options)

    assert conn.status == 200
    assert {"content-type", "text/calendar; charset=utf-8"} in conn.resp_headers
    assert conn.resp_body =~ "BEGIN:VFREEBUSY"
    assert conn.resp_body =~ "FREEBUSY;FBTYPE=BUSY:20260615T090000Z/20260615T100000Z"
  end

  test "reports when, and never what", context do
    event(context.options, "1.ics", [
      "SUMMARY:Divorce lawyer",
      "DESCRIPTION:Bring the bank statements",
      "LOCATION:Chancery Lane",
      "DTSTART:20260615T090000Z",
      "DTEND:20260615T100000Z"
    ])

    body = query(context.options).resp_body

    # The whole point of free-busy is that it can be shown to someone
    # who may not read the calendar.
    refute body =~ "Divorce"
    refute body =~ "bank statements"
    refute body =~ "Chancery"
    assert body =~ "20260615T090000Z/20260615T100000Z"
  end

  test "an empty window still returns a VFREEBUSY, with no FREEBUSY property", context do
    conn = query(context.options)

    assert conn.status == 200
    assert conn.resp_body =~ "BEGIN:VFREEBUSY"
    refute conn.resp_body =~ "FREEBUSY;"
  end

  describe "the TRANSP/STATUS table" do
    for {transp, status, expected} <- [
          {nil, nil, "BUSY"},
          {"OPAQUE", "CONFIRMED", "BUSY"},
          {nil, "TENTATIVE", "BUSY-TENTATIVE"},
          {nil, "CANCELLED", nil},
          {"TRANSPARENT", "CONFIRMED", nil},
          {"TRANSPARENT", "TENTATIVE", nil}
        ] do
      @transp transp
      @status status
      @expected expected

      test "TRANSP=#{inspect(transp)} STATUS=#{inspect(status)} is #{inspect(expected)}",
           context do
        properties =
          ["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"] ++
            List.wrap(@transp && "TRANSP:#{@transp}") ++
            List.wrap(@status && "STATUS:#{@status}")

        event(context.options, "1.ics", properties)
        body = query(context.options).resp_body

        if @expected do
          assert body =~ "FBTYPE=#{@expected}:20260615T090000Z"
        else
          refute body =~ "FREEBUSY;"
        end
      end
    end
  end

  test "touching periods of the same type coalesce into one", context do
    event(context.options, "1.ics", ["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"])
    event(context.options, "2.ics", ["DTSTART:20260615T100000Z", "DTEND:20260615T110000Z"])

    body = query(context.options).resp_body

    # Two back-to-back meetings are one stretch of being busy.
    assert body =~ "FREEBUSY;FBTYPE=BUSY:20260615T090000Z/20260615T110000Z"
  end

  test "periods of different types are kept apart", context do
    event(context.options, "1.ics", ["DTSTART:20260615T090000Z", "DTEND:20260615T120000Z"])

    event(context.options, "2.ics", [
      "DTSTART:20260615T100000Z",
      "DTEND:20260615T110000Z",
      "STATUS:TENTATIVE"
    ])

    body = query(context.options).resp_body

    assert body =~ "FBTYPE=BUSY:20260615T090000Z/20260615T120000Z"
    assert body =~ "FBTYPE=BUSY-TENTATIVE:20260615T100000Z/20260615T110000Z"
  end

  test "a period is clipped to the window asked about", context do
    event(context.options, "1.ics", ["DTSTART:20260501T000000Z", "DTEND:20260801T000000Z"])

    body = query(context.options).resp_body

    assert body =~ "FREEBUSY;FBTYPE=BUSY:20260601T000000Z/20260701T000000Z"
  end

  test "a recurrence contributes each of its instances", context do
    event(context.options, "1.ics", [
      "DTSTART:20260601T090000Z",
      "DTEND:20260601T100000Z",
      "RRULE:FREQ=WEEKLY;COUNT=3"
    ])

    body = unfolded(query(context.options))

    assert body =~ "20260601T090000Z/20260601T100000Z"
    assert body =~ "20260608T090000Z/20260608T100000Z"
    assert body =~ "20260615T090000Z/20260615T100000Z"
  end

  test "run against a calendar object, not a collection, is forbidden", context do
    event(context.options, "1.ics", ["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"])

    assert query(context.options, "/home/1.ics").status == 403
  end

  test "a body with no time-range is malformed", context do
    body = ~s(<?xml version="1.0"?><C:free-busy-query xmlns:C="#{Xml.caldav()}"/>)

    assert DavPlug.call(conn("REPORT", "/home", body), context.options).status == 400
  end

  test "long FREEBUSY lines are folded", context do
    for day <- 1..20 do
      start = "202606#{String.pad_leading("#{day}", 2, "0")}T0#{rem(day, 5) + 1}0000Z"
      finish = "202606#{String.pad_leading("#{day}", 2, "0")}T0#{rem(day, 5) + 1}3000Z"
      event(context.options, "#{day}.ics", ["DTSTART:#{start}", "DTEND:#{finish}"])
    end

    body = query(context.options).resp_body

    assert body =~ "\r\n "

    for line <- String.split(body, "\r\n") do
      assert byte_size(line) <= 75, "unfolded line of #{byte_size(line)} octets: #{line}"
    end
  end

  test "the report is advertised through supported-report-set", context do
    body =
      ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:supported-report-set/></D:prop></D:propfind>)

    conn =
      conn("PROPFIND", "/home", body)
      |> Conn.put_req_header("depth", "0")
      |> DavPlug.call(context.options)

    assert conn.resp_body =~ "<C:free-busy-query/>"
  end
end
