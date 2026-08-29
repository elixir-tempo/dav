defmodule Dav.Cal.MkcalendarTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.MemoryStore
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

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

    test "over something that exists is 405", context do
      mkcalendar("/home/work", context.writable)

      assert mkcalendar("/home/work", context.writable).status == 405
    end

    test "with a missing parent is 409", context do
      assert mkcalendar("/nothing/work", context.writable).status == 409
    end

    test "inside another calendar is forbidden", context do
      mkcalendar("/home/work", context.writable)

      assert mkcalendar("/home/work/nested", context.writable).status == 403
    end

    test "with a body is 415 rather than silently dropping the properties", context do
      body = ~s(<?xml version="1.0"?><C:mkcalendar xmlns:C="urn:ietf:params:xml:ns:caldav"/>)

      assert mkcalendar("/home/other", context.writable, body).status == 415
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

    test "an unregistered method is still refused by the base", context do
      plain = DavPlug.init(store: WritableStore, context: WritableStore.start([]))

      assert DavPlug.call(conn("MKCALENDAR", "/home/work"), plain).status == 405
    end
  end
end
