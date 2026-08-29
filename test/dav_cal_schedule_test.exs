defmodule Dav.Cal.ScheduleTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Cal.Schedule
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Plug.Conn

  doctest Dav.Cal.Schedule
  doctest Dav.Cal.FreeBusy, import: true

  setup do
    agent =
      SchedulingStore.start(
        [
          %Resource{path: [], collection?: true},
          %Resource{path: ["alice"], collection?: true},
          %Resource{path: ["alice", "outbox"], collection?: true, types: [Schedule.outbox()]},
          %Resource{path: ["alice", "inbox"], collection?: true, types: [Schedule.inbox()]},
          %Resource{path: ["bob"], collection?: true},
          %Resource{path: ["bob", "calendar"], collection?: true, types: [Cal.calendar()]}
        ],
        %{"mailto:bob@example.com" => ["bob"]}
      )

    options =
      DavPlug.init(store: SchedulingStore, context: agent, methods: [{"POST", Dav.Cal.Outbox}])

    busy =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:1",
          "DTSTART:20260615T090000Z",
          "DTEND:20260615T100000Z",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    DavPlug.call(conn("PUT", "/bob/calendar/1.ics", busy), options)
    %{options: options}
  end

  defp request(attendees, options) do
    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "METHOD:REQUEST",
          "BEGIN:VFREEBUSY",
          "ORGANIZER:mailto:alice@example.com"
        ] ++
          Enum.map(attendees, &"ATTENDEE:#{&1}") ++
          ["DTSTART:20260601T000000Z", "DTEND:20260701T000000Z", "END:VFREEBUSY", "END:VCALENDAR"],
        "\r\n"
      ) <> "\r\n"

    DavPlug.call(conn("POST", "/alice/outbox/", body), options)
  end

  test "a busy-time request is answered per recipient", context do
    conn = request(["mailto:bob@example.com"], context.options)

    assert conn.status == 200
    assert conn.resp_body =~ "schedule-response"
    assert conn.resp_body =~ "mailto:bob@example.com"
    assert conn.resp_body =~ "2.0;Success"
    assert conn.resp_body =~ "20260615T090000Z/20260615T100000Z"
  end

  test "an unknown recipient is named, not omitted", context do
    conn = request(["mailto:bob@example.com", "mailto:nobody@example.com"], context.options)

    # A recipient the server cannot answer for must still appear: an
    # absent one is indistinguishable from one the client forgot.
    assert conn.resp_body =~ "mailto:nobody@example.com"
    assert conn.resp_body =~ "3.7;Invalid calendar user"
  end

  test "an unknown recipient is never reported as free", context do
    conn = request(["mailto:nobody@example.com"], context.options)

    # The dangerous failure: answering "free" for someone never asked
    # about. There must be no VFREEBUSY at all for that recipient.
    refute conn.resp_body =~ "BEGIN:VFREEBUSY"
  end

  test "POST to something that is not an outbox is forbidden", context do
    body =
      "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VFREEBUSY\r\nEND:VFREEBUSY\r\nEND:VCALENDAR\r\n"

    assert DavPlug.call(conn("POST", "/bob/calendar", body), context.options).status == 403
  end

  test "a body that is not a busy-time request is a 400", context do
    body = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

    assert DavPlug.call(conn("POST", "/alice/outbox/", body), context.options).status == 400
  end

  test "the scheduling collections report their resource types", context do
    body =
      ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>)

    conn =
      conn("PROPFIND", "/alice/outbox", body)
      |> Conn.put_req_header("depth", "0")
      |> DavPlug.call(context.options)

    assert conn.resp_body =~ "schedule-outbox"
  end
end
