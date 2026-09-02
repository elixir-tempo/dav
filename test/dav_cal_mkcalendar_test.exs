defmodule Dav.Cal.MkcalendarTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.MemoryStore
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Plug.Conn

  setup do
    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["home"], collection?: true}
      ])

    %{
      writable:
        DavPlug.init(
          store: WritableStore,
          context: agent,
          methods: [{"MKCALENDAR", Dav.Cal.Mkcalendar}]
        ),
      read_only:
        DavPlug.init(
          store: MemoryStore,
          context: [%Resource{path: ["home"], collection?: true}],
          methods: [{"MKCALENDAR", Dav.Cal.Mkcalendar}]
        )
    }
  end

  defp mkcalendar(path, options, body \\ "") do
    DavPlug.call(conn("MKCALENDAR", path, body), options)
  end

  defp propfind(path, body, options) do
    conn("PROPFIND", path, body)
    |> put_req_header("depth", "0")
    |> DavPlug.call(options)
  end

  describe "MKCALENDAR" do
    test "creates a collection that reports CALDAV:calendar", context do
      assert mkcalendar("/home/work", context.writable).status == 201

      asked =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>)

      conn = propfind("/home/work", asked, context.writable)

      # Both elements, and the CalDAV namespace actually declared.
      assert conn.resp_body =~ "<D:collection/>"
      assert conn.resp_body =~ "<C:calendar/>"
      assert conn.resp_body =~ ~s(xmlns:C="urn:ietf:params:xml:ns:caldav")
    end

    test "over something that exists names DAV:resource-must-be-null", context do
      mkcalendar("/home/work", context.writable)
      conn = mkcalendar("/home/work", context.writable)

      # A bare 405 says the method was refused; the precondition says
      # the URL was already taken, which is what the client can act on.
      assert conn.status == 403
      assert conn.resp_body =~ "resource-must-be-null"
    end

    test "with a missing parent is 409", context do
      assert mkcalendar("/nothing/work", context.writable).status == 409
    end

    test "inside another calendar is forbidden", context do
      mkcalendar("/home/work", context.writable)

      assert mkcalendar("/home/work/nested", context.writable).status == 403
    end

    test "a body may name the new calendar, as the specification shows", context do
      # RFC 4791 section 5.3.1: "Clients can either specify the value of
      # the DAV:displayname property in the request body of the
      # MKCALENDAR request, or alternatively issue a PROPPATCH". A
      # server that refuses the body forces every client into the
      # second round trip.
      body = """
      <?xml version="1.0"?>
      <C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:set><D:prop><D:displayname>Work</D:displayname></D:prop></D:set>
      </C:mkcalendar>
      """

      assert mkcalendar("/home/other", context.writable, body).status == 201

      propfind =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:propfind>)

      conn =
        conn("PROPFIND", "/home/other", propfind)
        |> Conn.put_req_header("depth", "0")
        |> DavPlug.call(context.writable)

      assert conn.resp_body =~ "<D:displayname>Work</D:displayname>"
    end

    test "a body that is not a mkcalendar document is 415", context do
      assert mkcalendar("/home/nope", context.writable, "<not-mkcalendar/>").status == 415
    end
  end

  describe "advertisement" do
    test "a registered method appears in Allow", context do
      [allow] = DavPlug.call(conn("OPTIONS", "/"), context.writable) |> get_resp_header("allow")

      assert allow =~ "MKCALENDAR"
    end

    test "a store that cannot make calendars refuses the method", context do
      assert mkcalendar("/home/work", context.read_only).status == 405
    end

    test "an unregistered method is still refused by the base", _context do
      plain = DavPlug.init(store: WritableStore, context: WritableStore.start([]))

      assert DavPlug.call(conn("MKCALENDAR", "/home/work"), plain).status == 405
    end
  end
end
