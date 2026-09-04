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

  describe "sharing with groups" do
    setup do
      # Two groups, one member each way: `both` is in each of them, so
      # a calendar shared to both reaches them twice over.
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
            %Resource{path: ["both"], collection?: true, owner: "/p/both/"},
            %Resource{
              path: ["both", "notification"],
              collection?: true,
              types: [Sharing.notification()],
              owner: "/p/both/"
            },
            %Resource{path: ["teams"], collection?: true},
            %Resource{path: ["teams", "one"], collection?: true},
            %Resource{path: ["teams", "two"], collection?: true}
          ],
          %{
            "mailto:alice@example.com" => ["alice"],
            "mailto:both@example.com" => ["both"],
            "mailto:one@example.com" => ["teams", "one"],
            "mailto:two@example.com" => ["teams", "two"]
          },
          %{
            ["teams", "one"] => %{
              {"DAV:", "group-member-set"} => {:hrefs, ["mailto:both@example.com"]}
            },
            ["teams", "two"] => %{
              {"DAV:", "group-member-set"} => {:hrefs, ["mailto:both@example.com"]}
            }
          }
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

    defp invite(inner, options) do
      DavPlug.call(
        conn(
          "POST",
          "/alice/shared/",
          ~s(<?xml version="1.0" encoding="utf-8"?><CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">#{inner}</CS:share>)
        ),
        options
      )
    end

    defp sharees(options) do
      propfind("/alice/shared", "<CS:invite/>", options).resp_body
    end

    # The withdrawal names which share to take away, not who to take
    # it from. A member reached through a second group still holds
    # that group's share, and ending one of them is not ending both.
    test "uninviting one group leaves the share another group gave", context do
      invite(
        ~s(<CS:set><D:href>mailto:one@example.com</D:href><CS:read/></CS:set>),
        context.options
      )

      invite(
        ~s(<CS:set><D:href>mailto:two@example.com</D:href><CS:read/></CS:set>),
        context.options
      )

      assert sharees(context.options) =~ "mailto:both@example.com"

      invite(~s(<CS:remove><D:href>mailto:one@example.com</D:href></CS:remove>), context.options)

      assert sharees(context.options) =~ "mailto:both@example.com"
    end

    test "uninviting the last group that reached someone ends their share", context do
      invite(
        ~s(<CS:set><D:href>mailto:one@example.com</D:href><CS:read/></CS:set>),
        context.options
      )

      assert sharees(context.options) =~ "mailto:both@example.com"

      invite(~s(<CS:remove><D:href>mailto:one@example.com</D:href></CS:remove>), context.options)

      refute sharees(context.options) =~ "mailto:both@example.com"
    end
  end

  describe "quota on a shared calendar" do
    # The store keeps an account under `calendars/<scope>/<home>/`, so
    # the paths here have that shape rather than the short ones the
    # rest of this file uses.
    setup do
      agent =
        SchedulingStore.start(
          [
            %Resource{path: [], collection?: true},
            %Resource{path: ["calendars"], collection?: true},
            %Resource{path: ["calendars", "users"], collection?: true},
            %Resource{path: ~w(calendars users alice), collection?: true, owner: "/p/alice/"},
            %Resource{
              path: ~w(calendars users alice shared),
              collection?: true,
              types: [Cal.calendar()],
              owner: "/p/alice/"
            },
            %Resource{path: ~w(calendars users bob), collection?: true, owner: "/p/bob/"},
            %Resource{
              path: ~w(calendars users bob notification),
              collection?: true,
              types: [Sharing.notification()],
              owner: "/p/bob/"
            }
          ],
          %{
            "mailto:alice@example.com" => ~w(calendars users alice),
            "mailto:bob@example.com" => ~w(calendars users bob)
          }
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

    defp event(uid) do
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//test//EN",
        "BEGIN:VEVENT",
        "UID:#{uid}",
        "DTSTART:20270104T230000Z",
        "DURATION:PT1H",
        "DTSTAMP:20260101T000000Z",
        "SUMMARY:padded out so the size is worth measuring",
        "END:VEVENT",
        "END:VCALENDAR"
      ]
      |> Enum.join("\r\n")
      |> Kernel.<>("\r\n")
    end

    defp used(path, options) do
      body =
        propfind(path, "<D:quota-used-bytes/>", options).resp_body

      case Regex.run(~r|quota-used-bytes>(\d+)<|, body) do
        [_all, count] -> String.to_integer(count)
        nil -> nil
      end
    end

    defp shared(options) do
      DavPlug.call(
        conn(
          "POST",
          "/calendars/users/alice/shared/",
          ~s(<?xml version="1.0"?><CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/"><CS:set><D:href>mailto:bob@example.com</D:href><CS:read-write/></CS:set></CS:share>)
        ),
        options
      )
    end

    defp store(path, uid, options) do
      conn("PUT", path, event(uid))
      |> Conn.put_req_header("content-type", "text/calendar")
      |> DavPlug.call(options)
    end

    # A shared calendar is one calendar seen from two homes, and what
    # it holds is charged where it lives. Charging the writer instead
    # would let an owner fill somebody else's account by sharing a
    # calendar with them.
    test "what a sharee writes is charged to the owner", context do
      shared(context.options)

      # Measured after the invitation, since the notification it puts
      # in the sharee's own home is theirs and does count.
      alice = used("/calendars/users/alice", context.options)
      bob = used("/calendars/users/bob", context.options)

      assert store("/calendars/users/alice/shared/1.ics", "one", context.options).status in [
               201,
               204
             ]

      assert used("/calendars/users/alice", context.options) > alice
      assert used("/calendars/users/bob", context.options) == bob
    end

    # And every view of it reports the same figure: a sharee asking
    # how full the calendar is wants the answer about the calendar,
    # not about their own home.
    test "the calendar reports the owner's usage whoever asks", context do
      shared(context.options)

      store("/calendars/users/alice/shared/1.ics", "one", context.options)

      assert used("/calendars/users/alice/shared", context.options) ==
               used("/calendars/users/alice", context.options)
    end
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
