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
          %Resource{
            path: ["alice"],
            collection?: true,
            owner: "/principals/alice/",
            display_name: "Alice Adams"
          },
          %Resource{path: ["alice", "outbox"], collection?: true, types: [Schedule.outbox()]},
          %Resource{path: ["alice", "inbox"], collection?: true, types: [Schedule.inbox()]},
          %Resource{
            path: ["alice", "calendar"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/principals/alice/"
          },
          %Resource{path: ["bob"], collection?: true, owner: "/principals/bob/"},
          %Resource{
            path: ["bob", "calendar"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/principals/bob/"
          },
          %Resource{path: ["bob", "inbox"], collection?: true, types: [Schedule.inbox()]}
        ],
        %{"mailto:alice@example.com" => ["alice"], "mailto:bob@example.com" => ["bob"]}
      )

    options =
      DavPlug.init(
        store: SchedulingStore,
        context: agent,
        methods: [{"POST", Dav.Cal.Outbox}],
        hooks: [Dav.Cal.Scheduling]
      )

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
    assert conn.resp_body =~ "20260615T090000Z/PT1H"
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

  test "calendar data with no METHOD is not a scheduling message", context do
    # RFC 6638 section 5.2: a bare 400 tells a client its request was
    # wrong; the precondition tells it which rule it broke. Without a
    # METHOD this is a calendar object, not a message.
    body = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    conn = DavPlug.call(conn("POST", "/alice/outbox/", body), context.options)

    assert conn.status == 403
    assert conn.resp_body =~ "valid-calendar-data"
  end

  test "a METHOD with nothing to apply it to names valid-scheduling-message", context do
    body = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
    conn = DavPlug.call(conn("POST", "/alice/outbox/", body), context.options)

    assert conn.status == 403
    assert conn.resp_body =~ "valid-scheduling-message"
  end

  test "an ORGANIZER the poster may not act for is refused", context do
    # Posting on someone else's behalf is how a scheduling system is
    # abused, so the check is on identity, not on the message.
    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "METHOD:REQUEST",
          "BEGIN:VEVENT",
          "UID:1",
          "ORGANIZER:mailto:bob@example.com",
          "ATTENDEE:mailto:alice@example.com",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    conn = DavPlug.call(conn("POST", "/alice/outbox/", body), context.options)

    assert conn.status == 403
    assert conn.resp_body =~ "organizer-allowed"
  end

  test "a message with no recipients at all is refused", context do
    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "METHOD:REQUEST",
          "BEGIN:VEVENT",
          "UID:1",
          "ORGANIZER:mailto:alice@example.com",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    conn = DavPlug.call(conn("POST", "/alice/outbox/", body), context.options)

    assert conn.status == 403
    assert conn.resp_body =~ "recipient-specified"
  end

  test "an explicit event POST is accepted and delivers nothing", context do
    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "METHOD:REQUEST",
          "BEGIN:VEVENT",
          "UID:invite-1",
          "ORGANIZER:mailto:alice@example.com",
          "ATTENDEE:mailto:bob@example.com",
          "DTSTART:20260615T090000Z",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    conn = DavPlug.call(conn("POST", "/alice/outbox/", body), context.options)

    # RFC 6638 appendix A: on a server doing implicit scheduling, the
    # old explicit POST duplicates what the PUT already did, and a
    # compatible client would double-book every attendee. The request
    # succeeds; nothing is delivered.
    assert conn.status == 200

    listing =
      conn(
        "PROPFIND",
        "/bob/inbox",
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>)
      )
      |> Conn.put_req_header("depth", "1")
      |> DavPlug.call(context.options)

    refute listing.resp_body =~ "invite-1.ics"
  end

  test "a delivered scheduling message keeps its METHOD", context do
    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:invite-2",
          "ORGANIZER:mailto:alice@example.com",
          "ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@example.com",
          "DTSTART:20260615T090000Z",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    DavPlug.call(conn("PUT", "/alice/calendar/invite-2.ics", body), context.options)

    stored = DavPlug.call(conn("GET", "/bob/inbox/invite-2.ics", ""), context.options)

    # An Inbox holds scheduling *messages*, and the METHOD is what says
    # whether one is an invitation, a reply or a cancellation. RFC 4791
    # section 4.1 bans METHOD in a calendar collection; an Inbox is not
    # one, and stripping it makes every delivery ambiguous.
    assert stored.status == 200
    assert stored.resp_body =~ "METHOD:REQUEST"
  end

  describe "implicit scheduling" do
    test "storing an event with attendees delivers the invitations", context do
      # RFC 6638 section 3: neither party posts to an Outbox. An
      # organiser's calendar showing a meeting nobody was told about is
      # a failure that looks like success.
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:standup",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE:mailto:bob@example.com",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      assert DavPlug.call(conn("PUT", "/alice/calendar/standup.ics", event), context.options).status ==
               201

      delivered = DavPlug.call(conn("GET", "/bob/inbox/standup.ics", ""), context.options)

      assert delivered.status == 200
      assert delivered.resp_body =~ "METHOD:REQUEST"
    end

    test "an organiser who is also an attendee is not invited", context do
      # "The server MUST NOT send a scheduling message to the Attendee
      # that matches the Organizer."
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:solo",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE:mailto:alice@example.com",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      DavPlug.call(conn("PUT", "/alice/calendar/solo.ics", event), context.options)

      assert DavPlug.call(conn("GET", "/alice/inbox/solo.ics", ""), context.options).status == 404
    end

    test "an event with no organiser schedules nothing", context do
      event =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:private\r\nDTSTART:20260615T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert DavPlug.call(conn("PUT", "/alice/calendar/private.ics", event), context.options).status ==
               201

      # One person's private appointment: nobody needs telling.
      assert DavPlug.call(conn("GET", "/bob/inbox/private.ics", ""), context.options).status ==
               404
    end

    test "an attendee storing their copy replies to the organiser", context do
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:reply-1",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE;PARTSTAT=ACCEPTED:mailto:bob@example.com",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      DavPlug.call(conn("PUT", "/bob/calendar/reply-1.ics", event), context.options)

      replied = DavPlug.call(conn("GET", "/alice/inbox/reply-1.ics", ""), context.options)

      assert replied.status == 200
      assert replied.resp_body =~ "METHOD:REPLY"
    end
  end

  test "an attendee named only on an overridden instance is still invited", context do
    # A recurring event and its overrides are several components
    # sharing one UID. Taking only the first drops anyone invited to a
    # single occurrence rather than the series.
    event =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:series",
          "ORGANIZER:mailto:alice@example.com",
          "ATTENDEE:mailto:alice@example.com",
          "DTSTART:20260615T090000Z",
          "RRULE:FREQ=DAILY;COUNT=5",
          "END:VEVENT",
          "BEGIN:VEVENT",
          "UID:series",
          "RECURRENCE-ID:20260616T090000Z",
          "ORGANIZER:mailto:alice@example.com",
          "ATTENDEE:mailto:alice@example.com",
          "ATTENDEE:mailto:bob@example.com",
          "DTSTART:20260616T090000Z",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      ) <> "\r\n"

    assert DavPlug.call(conn("PUT", "/alice/calendar/series.ics", event), context.options).status ==
             201

    assert DavPlug.call(conn("GET", "/bob/inbox/series.ics", ""), context.options).status == 200
  end

  describe "re-delivery" do
    defp invitation(summary, partstat, extra \\ []) do
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:redeliver",
          "SUMMARY:#{summary}",
          "ORGANIZER:mailto:alice@example.com",
          "ATTENDEE;PARTSTAT=#{partstat}:mailto:bob@example.com",
          "DTSTART:20260615T090000Z"
        ] ++ extra ++ ["END:VEVENT", "END:VCALENDAR"],
        "\r\n"
      ) <> "\r\n"
    end

    test "an insignificant change does not un-accept the attendee", context do
      DavPlug.call(
        conn("PUT", "/alice/calendar/r.ics", invitation("One", "NEEDS-ACTION")),
        context.options
      )

      DavPlug.call(
        conn("PUT", "/bob/calendar/redeliver.ics", invitation("One", "ACCEPTED")),
        context.options
      )

      # An organiser fixing a typo re-delivers the whole event.
      # Overwriting the attendee's copy wholesale would reset their
      # acceptance and lose the record that their reply arrived. The
      # client echoes the answer the server showed it — writing
      # `NEEDS-ACTION` over a stored answer is the *other* thing, an
      # organiser deliberately asking again.
      DavPlug.call(
        conn("PUT", "/alice/calendar/r.ics", invitation("Two", "ACCEPTED")),
        context.options
      )

      stored =
        DavPlug.call(conn("GET", "/bob/calendar/redeliver.ics", ""), context.options).resp_body

      assert stored =~ "SUMMARY:Two"
      assert stored =~ "PARTSTAT=ACCEPTED"
      assert stored =~ "SCHEDULE-STATUS=1.2"
    end

    test "a significant change asks the attendee again", context do
      DavPlug.call(
        conn("PUT", "/alice/calendar/r.ics", invitation("One", "NEEDS-ACTION")),
        context.options
      )

      DavPlug.call(
        conn("PUT", "/bob/calendar/redeliver.ics", invitation("One", "ACCEPTED")),
        context.options
      )

      # Moving the event is a change to what the attendee agreed to,
      # and the organiser signals it by raising SEQUENCE.
      moved =
        invitation("One", "NEEDS-ACTION", ["SEQUENCE:1"])
        |> String.replace("DTSTART:20260615T090000Z", "DTSTART:20260616T140000Z")

      DavPlug.call(conn("PUT", "/alice/calendar/r.ics", moved), context.options)

      stored =
        DavPlug.call(conn("GET", "/bob/calendar/redeliver.ics", ""), context.options).resp_body

      refute stored =~ "PARTSTAT=ACCEPTED"
    end
  end

  describe "Schedule-Tag" do
    test "changes on every explicit client write", context do
      base = fn description ->
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:tagged",
            "DESCRIPTION:#{description}",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE:mailto:bob@example.com",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"
      end

      first = DavPlug.call(conn("PUT", "/alice/calendar/t.ics", base.("One")), context.options)
      [before] = Conn.get_resp_header(first, "schedule-tag")

      second = DavPlug.call(conn("PUT", "/alice/calendar/t.ics", base.("Two")), context.options)
      [after_edit] = Conn.get_resp_header(second, "schedule-tag")

      # The reference server's rule (`processScheduleTags` in
      # CalendarServer's `txdav/caldav/datastore/sql.py`): an explicit
      # client change always takes a fresh `Schedule-Tag`; only the
      # *server's* own update to the organiser's copy — applying an
      # attendee's reply — leaves it standing. The tag distinguishes
      # "somebody edited this" from "somebody answered this", not
      # "something scheduling-significant changed".
      refute before == after_edit
    end

    test "changes when the timing changes", context do
      base = fn start ->
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:moved",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE:mailto:bob@example.com",
            "DTSTART:#{start}",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"
      end

      first =
        DavPlug.call(
          conn("PUT", "/alice/calendar/m.ics", base.("20260615T090000Z")),
          context.options
        )

      [before] = Conn.get_resp_header(first, "schedule-tag")

      second =
        DavPlug.call(
          conn("PUT", "/alice/calendar/m.ics", base.("20260616T140000Z")),
          context.options
        )

      [moved] = Conn.get_resp_header(second, "schedule-tag")

      refute before == moved
    end

    test "an event with no attendees has none", context do
      private =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:solo\r\nDTSTART:20260615T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      conn = DavPlug.call(conn("PUT", "/alice/calendar/s.ics", private), context.options)

      assert Conn.get_resp_header(conn, "schedule-tag") == []
    end
  end

  describe "normalisation on write" do
    test "addresses and names are rewritten to canonical form", context do
      # One person may arrive as `mailto:`, a bare address, or a URN
      # depending on the client. A copy that keeps whichever spelling
      # it was given cannot be compared with any other copy.
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:norm",
            "ORGANIZER;CN=Made Up:mailto:alice@example.com",
            "ATTENDEE:mailto:bob@example.com",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      DavPlug.call(conn("PUT", "/alice/calendar/n.ics", event), context.options)

      stored = DavPlug.call(conn("GET", "/alice/calendar/n.ics", ""), context.options).resp_body

      # The CN is the server's to state: a client writing a name for
      # someone who has one would have every participant see the
      # invention rather than the person.
      assert stored =~ "CN=Alice Adams"
      refute stored =~ "Made Up"
    end

    test "an object already in canonical form is not rewritten", context do
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:stable",
            "SUMMARY:Fixed",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      DavPlug.call(conn("PUT", "/alice/calendar/stable.ics", event), context.options)

      assert DavPlug.call(conn("GET", "/alice/calendar/stable.ics", ""), context.options).resp_body ==
               event
    end
  end

  describe "the organiser's view of participation" do
    defp meeting(summary, sequence \\ []) do
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "UID:parts",
          "SUMMARY:#{summary}",
          "ORGANIZER:mailto:alice@example.com",
          # `DECLINED` from the organiser is a claim about what Bob
          # decided, which is not theirs to make. `NEEDS-ACTION` would
          # be a different thing — the question being put again — and
          # is tested separately.
          "ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com",
          "DTSTART:20260615T090000Z"
        ] ++ sequence ++ ["END:VEVENT", "END:VCALENDAR"],
        "\r\n"
      ) <> "\r\n"
    end

    defp accepted do
      String.replace(meeting("One"), "PARTSTAT=DECLINED", "PARTSTAT=ACCEPTED")
    end

    test "an organiser may put the question again", context do
      asked =
        meeting("Two")
        |> String.replace("PARTSTAT=DECLINED", "PARTSTAT=NEEDS-ACTION")

      DavPlug.call(conn("PUT", "/alice/calendar/q.ics", meeting("One")), context.options)
      DavPlug.call(conn("PUT", "/bob/calendar/parts.ics", accepted()), context.options)

      DavPlug.call(conn("PUT", "/alice/calendar/q.ics", asked), context.options)

      stored = DavPlug.call(conn("GET", "/alice/calendar/q.ics", ""), context.options).resp_body

      # Not an organiser overwriting somebody's answer: `NEEDS-ACTION`
      # is the one value that says "I am asking again", and the
      # attendee is put back to being asked — with `RSVP` on the
      # delivered update to say a reply is wanted.
      assert stored =~ "PARTSTAT=NEEDS-ACTION"
      assert stored =~ "RSVP=TRUE"
    end

    test "putting the question again is worth sending on its own", context do
      asked = String.replace(meeting("One"), "PARTSTAT=DECLINED", "PARTSTAT=NEEDS-ACTION")

      DavPlug.call(conn("PUT", "/alice/calendar/r.ics", meeting("One")), context.options)
      DavPlug.call(conn("PUT", "/bob/calendar/parts.ics", accepted()), context.options)

      DavPlug.call(conn("PUT", "/alice/calendar/r.ics", asked), context.options)

      stored = DavPlug.call(conn("GET", "/alice/calendar/r.ics", ""), context.options).resp_body
      theirs = DavPlug.call(conn("GET", "/bob/calendar/parts.ics", ""), context.options).resp_body

      # Nothing else about the event moved, so the reset is the whole
      # change. Leaving `PARTSTAT` out of the comparison that decides
      # whether a save is worth announcing had the question asked in
      # the organiser's own copy and never put to anybody: the version
      # stayed where it was, the delivery mark stayed at the old
      # reply, and the attendee went on holding their acceptance.
      assert stored =~ "SEQUENCE:1"
      assert stored =~ "SCHEDULE-STATUS=1.2"
      assert theirs =~ "PARTSTAT=NEEDS-ACTION"
    end

    test "an organiser does not answer for an attendee", context do
      DavPlug.call(conn("PUT", "/alice/calendar/p.ics", meeting("One")), context.options)
      DavPlug.call(conn("PUT", "/bob/calendar/parts.ics", accepted()), context.options)

      DavPlug.call(conn("PUT", "/alice/calendar/p.ics", meeting("Two")), context.options)

      stored = DavPlug.call(conn("GET", "/alice/calendar/p.ics", ""), context.options).resp_body

      # RFC 6638 section 3.2.1: an organiser may not set another
      # participant's PARTSTAT. Writing the client's view over the
      # server's own would un-accept everyone on every edit.
      assert stored =~ "PARTSTAT=ACCEPTED"
      # The invitation was re-delivered, so the status returns to
      # "delivered" rather than staying at "replied".
      assert stored =~ "SCHEDULE-STATUS=1.2"
    end

    test "a change of timing asks the attendees again", context do
      DavPlug.call(conn("PUT", "/alice/calendar/p.ics", meeting("One")), context.options)
      DavPlug.call(conn("PUT", "/bob/calendar/parts.ics", accepted()), context.options)

      moved =
        meeting("One", ["SEQUENCE:1"])
        |> String.replace("DTSTART:20260615T090000Z", "DTSTART:20260620T140000Z")

      DavPlug.call(conn("PUT", "/alice/calendar/p.ics", moved), context.options)

      stored = DavPlug.call(conn("GET", "/alice/calendar/p.ics", ""), context.options).resp_body

      # RFC 6638 section 3.2.8: when the meeting moves, the attendees
      # are being asked about a different meeting, so their last
      # answer is withdrawn and the question put again. Only *timing*
      # counts — an event called off, or moved down the corridor, is
      # news they need without having to answer for it a second time,
      # and treating those as re-asks lost more of the conformance
      # suite than it won.
      assert stored =~ "PARTSTAT=NEEDS-ACTION"
      assert stored =~ "RSVP=TRUE"
    end
  end

  describe "the ETag a scheduling write reports" do
    test "names the version the store actually holds", context do
      event =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "UID:validator",
            "SUMMARY:Meeting",
            "ORGANIZER:mailto:alice@example.com",
            "ATTENDEE:mailto:bob@example.com",
            "DTSTART:20260615T090000Z",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      written = DavPlug.call(conn("PUT", "/alice/calendar/v.ics", event), context.options)

      # RFC 4791 section 5.3.4: scheduling rewrites the organiser's
      # copy after the write — stamping `SCHEDULE-STATUS`, settling
      # participation — so the stored version is not the one the
      # client sent, and no `ETag` may be returned for it. A validator
      # answered here would describe a version that never existed, and
      # a client sending it back would have its own write refused for
      # a change the server made itself.
      assert [] == Conn.get_resp_header(written, "etag")

      # The version the store holds is still available to ask for, and
      # is the one a conditional write must quote.
      stored = DavPlug.call(conn("GET", "/alice/calendar/v.ics", ""), context.options)
      [held] = Conn.get_resp_header(stored, "etag")

      again =
        DavPlug.call(
          conn("PUT", "/alice/calendar/v.ics", event)
          |> Conn.put_req_header("if-match", held),
          context.options
        )

      assert again.status == 204
    end
  end
end
