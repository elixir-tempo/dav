defmodule Dav.Web.ProppatchTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.MemoryStore
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

  setup do
    agent = WritableStore.start([%Resource{path: []}, %Resource{path: ["note.txt"]}])

    %{
      writable: DavPlug.init(store: WritableStore, context: agent),
      read_only: DavPlug.init(store: MemoryStore, context: [%Resource{path: ["note.txt"]}])
    }
  end

  defp patch(path, body, options) do
    DavPlug.call(conn("PROPPATCH", path, body), options)
  end

  defp propfind(path, body, options) do
    conn("PROPFIND", path, body)
    |> put_req_header("depth", "0")
    |> DavPlug.call(options)
  end

  defp update(inner) do
    ~s(<?xml version="1.0" encoding="utf-8"?><D:propertyupdate xmlns:D="DAV:" xmlns:x="http://example.test/">#{inner}</D:propertyupdate>)
  end

  describe "setting and removing" do
    test "a dead property survives a round trip", context do
      body = update(~s(<D:set><D:prop><x:colour>red</x:colour></D:prop></D:set>))
      assert patch("/note.txt", body, context.writable).status == 207

      asked =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:x="http://example.test/"><D:prop><x:colour/></D:prop></D:propfind>)

      conn = propfind("/note.txt", asked, context.writable)

      assert conn.resp_body =~ ">red<"
      assert conn.resp_body =~ "HTTP/1.1 200 OK"
    end

    test "removing takes it away again", context do
      patch(
        "/note.txt",
        update(~s(<D:set><D:prop><x:colour>red</x:colour></D:prop></D:set>)),
        context.writable
      )

      patch(
        "/note.txt",
        update(~s(<D:remove><D:prop><x:colour/></D:prop></D:remove>)),
        context.writable
      )

      asked =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:x="http://example.test/"><D:prop><x:colour/></D:prop></D:propfind>)

      assert propfind("/note.txt", asked, context.writable).resp_body =~ "404 Not Found"
    end

    test "instructions are applied in document order", context do
      # Set then remove leaves nothing; the reverse would leave the value.
      body =
        update(
          ~s(<D:set><D:prop><x:colour>red</x:colour></D:prop></D:set>) <>
            ~s(<D:remove><D:prop><x:colour/></D:prop></D:remove>)
        )

      patch("/note.txt", body, context.writable)

      asked =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:x="http://example.test/"><D:prop><x:colour/></D:prop></D:propfind>)

      assert propfind("/note.txt", asked, context.writable).resp_body =~ "404 Not Found"
    end
  end

  describe "atomicity" do
    test "a protected property is refused", context do
      body = update(~s(<D:set><D:prop><D:getetag>forged</D:getetag></D:prop></D:set>))
      conn = patch("/note.txt", body, context.writable)

      assert conn.status == 207
      assert conn.resp_body =~ "403 Forbidden"
    end

    test "and everything else in the request fails with it, as 424", context do
      body =
        update(
          ~s(<D:set><D:prop><D:getetag>forged</D:getetag><x:colour>red</x:colour></D:prop></D:set>)
        )

      conn = patch("/note.txt", body, context.writable)

      assert conn.resp_body =~ "403 Forbidden"
      # Failed Dependency: it would have worked, and did not, because
      # of the other one.
      assert conn.resp_body =~ "424 Failed Dependency"
    end

    test "a refused request changes nothing", context do
      patch(
        "/note.txt",
        update(~s(<D:set><D:prop><x:colour>green</x:colour></D:prop></D:set>)),
        context.writable
      )

      body =
        update(
          ~s(<D:set><D:prop><D:getetag>forged</D:getetag><x:colour>red</x:colour></D:prop></D:set>)
        )

      patch("/note.txt", body, context.writable)

      asked =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:x="http://example.test/"><D:prop><x:colour/></D:prop></D:propfind>)

      # Still green: the whole instruction set was abandoned.
      assert propfind("/note.txt", asked, context.writable).resp_body =~ ">green<"
    end
  end

  describe "refusals" do
    test "a store that cannot patch does not advertise PROPPATCH", context do
      conn = DavPlug.call(conn("OPTIONS", "/"), context.read_only)
      [allow] = get_resp_header(conn, "allow")

      refute allow =~ "PROPPATCH"
      assert patch("/note.txt", update(""), context.read_only).status == 405
    end

    test "a body that is not a propertyupdate is 400", context do
      assert patch("/note.txt", ~s(<D:propfind xmlns:D="DAV:"/>), context.writable).status == 400
    end
  end
end
