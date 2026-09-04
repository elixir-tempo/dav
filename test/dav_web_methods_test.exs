defmodule Dav.Web.MethodsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.MemoryStore
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

  setup do
    resources = [
      %Resource{path: [], collection?: true},
      %Resource{path: ["files"], collection?: true},
      %Resource{path: ["files", "note.txt"], content_type: "text/plain", etag: ~s("v1")}
    ]

    agent = WritableStore.start(resources)

    %{
      writable: DavPlug.init(store: WritableStore, context: agent),
      read_only: DavPlug.init(store: MemoryStore, context: resources)
    }
  end

  defp send_request(method, path, options, body \\ "", headers \\ []) do
    conn =
      Enum.reduce(headers, conn(method, path, body), fn {k, v}, conn ->
        put_req_header(conn, k, v)
      end)

    DavPlug.call(conn, options)
  end

  defp listing(context) do
    DavPlug.init(store: WritableStore, context: context.writable.context, listings: true)
  end

  describe "a store's capabilities decide the server's" do
    test "a read-only store advertises no write methods", context do
      conn = send_request("OPTIONS", "/", context.read_only)
      [allow] = get_resp_header(conn, "allow")

      assert allow =~ "PROPFIND"
      assert allow =~ "REPORT"
      refute allow =~ "PUT"
      refute allow =~ "DELETE"
      refute allow =~ "MKCOL"
      # It cannot even read bodies, having no read/2.
      refute allow =~ "GET"
    end

    test "a writable store advertises them", context do
      conn = send_request("OPTIONS", "/", context.writable)
      [allow] = get_resp_header(conn, "allow")

      for method <- ~w(GET HEAD PUT DELETE MKCOL PROPFIND REPORT), do: assert(allow =~ method)
    end

    test "a method the store cannot do is refused, not attempted", context do
      conn = send_request("PUT", "/files/new.txt", context.read_only, "x")

      assert conn.status == 405
      refute get_resp_header(conn, "allow") == []
    end
  end

  describe "GET" do
    test "returns the body, its type and its ETag", context do
      send_request("PUT", "/files/a.txt", context.writable, "hello", [
        {"content-type", "text/plain"}
      ])

      conn = send_request("GET", "/files/a.txt", context.writable)

      assert conn.status == 200
      assert conn.resp_body == "hello"
      assert get_resp_header(conn, "etag") != []
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "HEAD is the same without the body", context do
      send_request("PUT", "/files/a.txt", context.writable, "hello")
      conn = send_request("HEAD", "/files/a.txt", context.writable)

      assert conn.status == 200
      assert conn.resp_body == ""
    end

    test "a collection is refused rather than given an invented listing", context do
      conn = send_request("GET", "/files/", context.writable)

      assert conn.status == 405
    end

    # RFC 3986 section 5: a relative reference resolves against the
    # base, and `/files` and `/files/` are different bases. A member
    # named `note.txt` resolves to `/note.txt` from the first and
    # `/files/note.txt` from the second, so the client is sent to the
    # address the collection actually has.
    test "a collection addressed without its trailing slash is moved", context do
      conn = send_request("GET", "/files", context.writable)

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/files/"]
    end

    test "a document is not moved, whatever its name looks like", context do
      conn = send_request("GET", "/files/note.txt", context.writable)

      assert conn.status == 200
    end

    test "a listing is served where the deployment asked for one", context do
      conn = send_request("GET", "/files/", listing(context))

      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/html"
      assert conn.resp_body =~ ~s(<a href="/files/note.txt">note.txt</a>)
      assert conn.resp_body =~ "<td>text/plain</td>"
    end

    # A person and a calendar client asking the same URL want
    # different answers, and the only thing that separates them is
    # what they say they are.
    test "a browser is given the listing even where nothing else asked for one", context do
      conn =
        send_request("GET", "/files/", listing(context), "", [
          {"user-agent", "Mozilla/5.0 (Macintosh)"}
        ])

      assert conn.status == 200
      assert conn.resp_body =~ "<td>text/plain</td>"
    end

    # RFC 9110 section 13.1. A calendar home polled every minute is
    # the case this exists for: the point is the body that is not sent.
    test "a collection GET is conditional on its validator", context do
      conn = send_request("GET", "/files/", listing(context))

      assert [validator] = get_resp_header(conn, "etag")

      again = send_request("GET", "/files/", listing(context), "", [{"if-none-match", validator}])

      assert again.status == 304
      assert again.resp_body == ""
    end

    # The validator is over the rendering, not over the store's idea
    # of the collection: what the client is holding is the listing,
    # and a listing that changed is a different entity.
    test "a listing that changes gets a new validator", context do
      before = send_request("GET", "/files/", listing(context))

      send_request("PUT", "/files/other.txt", context.writable, "x", [
        {"content-type", "text/plain"}
      ])

      after_write = send_request("GET", "/files/", listing(context))

      assert get_resp_header(before, "etag") != get_resp_header(after_write, "etag")
    end

    test "something absent is 404", context do
      conn = send_request("GET", "/files/nowhere.txt", context.writable)

      assert conn.status == 404
    end
  end

  describe "PUT" do
    test "creating is 201 and replacing is 204", context do
      created = send_request("PUT", "/files/b.txt", context.writable, "one")
      replaced = send_request("PUT", "/files/b.txt", context.writable, "two")

      assert created.status == 201
      assert replaced.status == 204
    end

    test "the ETag changes when the content does", context do
      one = send_request("PUT", "/files/c.txt", context.writable, "one")
      two = send_request("PUT", "/files/c.txt", context.writable, "two")

      assert get_resp_header(one, "etag") != get_resp_header(two, "etag")
    end

    test "a missing parent is a conflict, not an invitation to create it", context do
      conn = send_request("PUT", "/nothing/here.txt", context.writable, "x")

      assert conn.status == 409
    end
  end

  describe "DELETE" do
    test "removes a resource", context do
      send_request("PUT", "/files/d.txt", context.writable, "x")
      deleted = send_request("DELETE", "/files/d.txt", context.writable)

      assert deleted.status == 204
      assert send_request("GET", "/files/d.txt", context.writable).status == 404
    end

    test "removes a collection and everything under it", context do
      send_request("MKCOL", "/files/sub", context.writable)
      send_request("PUT", "/files/sub/e.txt", context.writable, "x")
      send_request("DELETE", "/files/sub", context.writable)

      assert send_request("GET", "/files/sub/e.txt", context.writable).status == 404
    end

    test "deleting what is not there is 404", context do
      assert send_request("DELETE", "/files/gone.txt", context.writable).status == 404
    end
  end

  describe "MKCOL" do
    test "creates a collection", context do
      conn = send_request("MKCOL", "/files/new", context.writable)

      assert conn.status == 201

      assert send_request("PROPFIND", "/files/new", context.writable, "", [{"depth", "0"}]).status ==
               207
    end

    test "over something that exists is 405", context do
      assert send_request("MKCOL", "/files", context.writable).status == 405
    end

    test "with a missing parent is 409", context do
      assert send_request("MKCOL", "/nothing/deep", context.writable).status == 409
    end

    test "with a body is 415 — that is extended MKCOL, which this is not", context do
      conn = send_request("MKCOL", "/files/other", context.writable, "<D:mkcol/>")

      assert conn.status == 415
    end
  end

  describe "conditional requests" do
    test "PUT with a stale If-Match is refused", context do
      conn =
        send_request("PUT", "/files/note.txt", context.writable, "new", [{"if-match", ~s("gone")}])

      # `412` and not `409`: the request was well formed and the
      # server understood it, but the resource is no longer what the
      # client believed it was overwriting.
      assert conn.status == 412
      assert send_request("GET", "/files/note.txt", context.writable).resp_body != "new"
    end

    test "PUT with a matching If-Match proceeds", context do
      etag = send_request("GET", "/files/note.txt", context.writable) |> get_resp_header("etag")

      conn =
        send_request("PUT", "/files/note.txt", context.writable, "new", [{"if-match", hd(etag)}])

      assert conn.status == 204
    end

    test "If-Match: * requires the resource to exist", context do
      assert send_request("PUT", "/files/note.txt", context.writable, "x", [{"if-match", "*"}]).status ==
               204

      assert send_request("PUT", "/files/new.txt", context.writable, "x", [{"if-match", "*"}]).status ==
               412
    end

    test "If-None-Match: * refuses to overwrite", context do
      assert send_request("PUT", "/files/note.txt", context.writable, "x", [
               {"if-none-match", "*"}
             ]).status == 412

      # The point of the header: creating a resource without racing
      # another client creating the same one.
      assert send_request("PUT", "/files/new.txt", context.writable, "x", [
               {"if-none-match", "*"}
             ]).status == 201
    end

    test "DELETE with a stale If-Match is refused", context do
      conn =
        send_request("DELETE", "/files/note.txt", context.writable, "", [{"if-match", ~s("gone")}])

      assert conn.status == 412
      assert send_request("GET", "/files/note.txt", context.writable).status == 200
    end
  end
end
