defmodule Dav.Web.TransferTest do
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
        %Resource{path: ["files"], collection?: true},
        %Resource{path: ["other"], collection?: true}
      ])

    options = DavPlug.init(store: WritableStore, context: agent)
    DavPlug.call(conn("PUT", "/files/a.txt", "one"), options)

    %{
      writable: options,
      read_only: DavPlug.init(store: MemoryStore, context: [%Resource{path: ["files"]}])
    }
  end

  defp transfer(method, from, to, options, headers \\ []) do
    conn("#{method}", from)
    |> put_req_header("destination", "http://www.example.com#{to}")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> DavPlug.call(options)
  end

  defp exists?(path, options) do
    DavPlug.call(conn("GET", path), options).status == 200
  end

  describe "COPY" do
    test "duplicates, leaving the source in place", context do
      conn = transfer("COPY", "/files/a.txt", "/other/b.txt", context.writable)

      assert conn.status == 201
      assert exists?("/files/a.txt", context.writable)
      assert exists?("/other/b.txt", context.writable)
    end

    test "over an existing destination is 204, not 201", context do
      DavPlug.call(conn("PUT", "/other/b.txt", "x"), context.writable)
      conn = transfer("COPY", "/files/a.txt", "/other/b.txt", context.writable)

      assert conn.status == 204
    end

    test "copies a collection and everything under it", context do
      conn = transfer("COPY", "/files", "/other/files", context.writable)

      assert conn.status == 201
      assert exists?("/other/files/a.txt", context.writable)
    end
  end

  describe "MOVE" do
    test "relocates, leaving nothing behind", context do
      conn = transfer("MOVE", "/files/a.txt", "/other/b.txt", context.writable)

      assert conn.status == 201
      refute exists?("/files/a.txt", context.writable)
      assert exists?("/other/b.txt", context.writable)
    end
  end

  describe "the rules both share" do
    test "a missing Destination is 400", context do
      conn = DavPlug.call(conn("COPY", "/files/a.txt"), context.writable)

      assert conn.status == 400
    end

    test "Overwrite: F against an occupied destination is 412", context do
      DavPlug.call(conn("PUT", "/other/b.txt", "x"), context.writable)

      conn =
        transfer("COPY", "/files/a.txt", "/other/b.txt", context.writable, [{"overwrite", "F"}])

      assert conn.status == 412
    end

    test "Overwrite: F against a free destination proceeds", context do
      conn =
        transfer("COPY", "/files/a.txt", "/other/free.txt", context.writable, [{"overwrite", "F"}])

      assert conn.status == 201
    end

    test "a missing intermediate collection is 409, never created", context do
      conn = transfer("COPY", "/files/a.txt", "/nothing/deep/b.txt", context.writable)

      assert conn.status == 409
      refute exists?("/nothing/deep/b.txt", context.writable)
    end

    test "source and destination being the same is 403", context do
      conn = transfer("COPY", "/files/a.txt", "/files/a.txt", context.writable)

      assert conn.status == 403
    end

    test "a destination on another host is 502, not a guess", context do
      conn =
        conn("COPY", "/files/a.txt")
        |> put_req_header("destination", "http://elsewhere.test/other/b.txt")
        |> DavPlug.call(context.writable)

      assert conn.status == 502
    end

    test "a source that is not there is 404", context do
      conn = transfer("MOVE", "/files/gone.txt", "/other/b.txt", context.writable)

      assert conn.status == 404
    end

    test "a store that cannot move does not advertise MOVE", context do
      allow = DavPlug.call(conn("OPTIONS", "/"), context.read_only) |> get_resp_header("allow")

      refute hd(allow) =~ "MOVE"
      refute hd(allow) =~ "COPY"
    end
  end
end
