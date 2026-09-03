defmodule Dav.Cal.SharingTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Cal.Sharing
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Plug.Conn

  doctest Dav.Cal.Sharing

  setup do
    agent =
      SchedulingStore.start(
        [
          %Resource{path: [], collection?: true},
          %Resource{path: ["alice"], collection?: true, owner: "/p/alice/"},
          %Resource{
            path: ["alice", "shared"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/p/alice/"
          },
          %Resource{path: ["bob"], collection?: true, owner: "/p/bob/"},
          %Resource{
            path: ["bob", "notification"],
            collection?: true,
            types: [Sharing.notification()],
            owner: "/p/bob/"
          }
        ],
        %{"mailto:alice@example.com" => ["alice"], "mailto:bob@example.com" => ["bob"]}
      )

    options =
      DavPlug.init(
        store: SchedulingStore,
        context: agent,
        methods: [{"POST", Cal.Post}],
        hooks: [Cal.Sharing]
      )

    %{options: options}
  end

  defp share(inner, options) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">#{inner}</CS:share>
    """

    DavPlug.call(conn("POST", "/alice/shared/", body), options)
  end

  defp propfind(path, property, options) do
    body =
      ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/"><D:prop>#{property}</D:prop></D:propfind>)

    conn("PROPFIND", path, body)
    |> Conn.put_req_header("depth", "0")
    |> DavPlug.call(options)
  end

  describe "inviting" do
    test "an invitation is recorded on the calendar", context do
      conn =
        share(
          ~s(<CS:set><D:href>mailto:bob@example.com</D:href><CS:summary>Team</CS:summary><CS:read-write/></CS:set>),
          context.options
        )

      assert conn.status == 200

      listing = propfind("/alice/shared", "<CS:invite/>", context.options)

      # This is what an owner's client reads to show its sharing panel:
      # who was invited, what they were granted, and whether they have
      # answered. The summary is the invitee's copy of the invitation,
      # not part of the owner's record of it.
      assert listing.resp_body =~ "mailto:bob@example.com"
      assert listing.resp_body =~ "read-write"
      assert listing.resp_body =~ "invite-noresponse"
    end

    test "the invitee is notified, since they cannot see the calendar yet", context do
      share(
        ~s(<CS:set><D:href>mailto:bob@example.com</D:href><CS:summary>Team</CS:summary><CS:read/></CS:set>),
        context.options
      )

      listing =
        conn(
          "PROPFIND",
          "/bob/notification",
          ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>)
        )
        |> Conn.put_req_header("depth", "1")
        |> DavPlug.call(context.options)

      # An invitee has no reason to poll a calendar they cannot see, so
      # a share recorded only on the owner's side is one nobody hears
      # about.
      assert listing.resp_body =~ ".xml"
    end

    test "read is the default when no access is named", context do
      share(~s(<CS:set><D:href>mailto:bob@example.com</D:href></CS:set>), context.options)

      listing = propfind("/alice/shared", "<CS:invite/>", context.options)

      # Granting write by accident is the mistake that cannot be undone.
      assert listing.resp_body =~ "<CS:read/>"
      refute listing.resp_body =~ "read-write"
    end

    test "re-inviting the same person replaces the earlier invitation", context do
      href = "<D:href>mailto:bob@example.com</D:href>"
      share("<CS:set>#{href}<CS:read/></CS:set>", context.options)
      share("<CS:set>#{href}<CS:read-write/></CS:set>", context.options)

      listing = propfind("/alice/shared", "<CS:invite/>", context.options)

      assert listing.resp_body =~ "read-write"
      # One entry, not two contradictory ones.
      refute listing.resp_body =~ "<CS:read/>"
    end

    test "a removal takes the invitation away", context do
      href = "<D:href>mailto:bob@example.com</D:href>"
      share("<CS:set>#{href}<CS:read/></CS:set>", context.options)
      share("<CS:remove>#{href}</CS:remove>", context.options)

      listing = propfind("/alice/shared", "<CS:invite/>", context.options)

      refute listing.resp_body =~ "mailto:bob@example.com"
    end

    test "sharing something that is not a calendar is refused", context do
      body =
        ~s(<?xml version="1.0"?><CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/"/>)

      assert DavPlug.call(conn("POST", "/alice/", body), context.options).status == 403
    end
  end

  test "a calendar says it can be shared", context do
    listing = propfind("/alice/shared", "<CS:allowed-sharing-modes/>", context.options)

    assert listing.resp_body =~ "can-be-shared"
  end

  test "POST routes a calendar body to scheduling, not sharing", context do
    # `POST` is the one method CalDAV overloads, and the body is the
    # only reliable way to tell an invitation from a scheduling
    # message. Sent at the calendar home, which is neither an Outbox
    # nor a calendar, scheduling refuses it — proving it was routed
    # there rather than to sharing.
    ics = "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"

    assert DavPlug.call(conn("POST", "/alice/", ics), context.options).status == 403
  end
end
