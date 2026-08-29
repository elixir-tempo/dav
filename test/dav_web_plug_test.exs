defmodule Dav.Web.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.MemoryStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

  setup do
    resources = [
      %Resource{path: [], collection?: true, display_name: "Root"},
      %Resource{path: ["calendars"], collection?: true, display_name: "Calendars"},
      %Resource{
        path: ["calendars", "meeting.ics"],
        etag: ~s("v1"),
        content_type: "text/calendar",
        content_length: 42,
        modified_at: ~U[1994-11-15 12:45:26Z]
      }
    ]

    %{options: DavPlug.init(store: MemoryStore, context: resources)}
  end

  defp request(method, path, body \\ "", headers \\ []) do
    Enum.reduce(headers, conn(method, path, body), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
  end

  describe "OPTIONS" do
    test "advertises only the classes actually implemented", context do
      conn = DavPlug.call(request("OPTIONS", "/"), context.options)

      assert conn.status == 200
      # Class 1 only. Claiming 2 without LOCK is worse than not claiming it.
      assert get_resp_header(conn, "dav") == ["1"]
      refute get_resp_header(conn, "dav") == ["1, 2"]
    end

    test "the Allow header does not promise methods that are not there", context do
      conn = DavPlug.call(request("OPTIONS", "/"), context.options)
      [allow] = get_resp_header(conn, "allow")

      assert allow =~ "PROPFIND"
      refute allow =~ "LOCK"
      refute allow =~ "PUT"
    end
  end

  describe "unimplemented methods" do
    test "are refused with an honest Allow header", context do
      conn = DavPlug.call(request("LOCK", "/calendars"), context.options)

      assert conn.status == 405
      assert get_resp_header(conn, "allow") != []
    end
  end

  describe "PROPFIND" do
    test "an empty body means allprop, which is what several clients send", context do
      conn = DavPlug.call(request("PROPFIND", "/calendars", ""), context.options)

      assert conn.status == 207
      assert conn.resp_body =~ "<D:displayname>Calendars</D:displayname>"
    end

    test "Depth: 0 reports the collection alone", context do
      conn =
        DavPlug.call(
          request("PROPFIND", "/calendars", "", [{"depth", "0"}]),
          context.options
        )

      assert conn.status == 207
      assert conn.resp_body |> String.split("<D:response>") |> length() == 2
    end

    test "Depth: 1 reports the collection and its members", context do
      conn =
        DavPlug.call(
          request("PROPFIND", "/calendars", "", [{"depth", "1"}]),
          context.options
        )

      assert conn.status == 207
      assert conn.resp_body =~ "<D:href>/calendars/</D:href>"
      assert conn.resp_body =~ "<D:href>/calendars/meeting.ics</D:href>"
    end

    test "a collection is marked as one, and a plain resource is not", context do
      conn =
        DavPlug.call(
          request("PROPFIND", "/calendars", "", [{"depth", "1"}]),
          context.options
        )

      assert conn.resp_body =~ "<D:resourcetype><D:collection/></D:resourcetype>"
      assert conn.resp_body =~ "<D:resourcetype/>"
    end

    test "asking for named properties splits found from missing", context do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:">
        <D:prop><D:getetag/><D:getcontenttype/><D:invented-by-a-client/></D:prop>
      </D:propfind>
      """

      conn =
        DavPlug.call(
          request("PROPFIND", "/calendars/meeting.ics", body, [{"depth", "0"}]),
          context.options
        )

      assert conn.status == 207
      assert conn.resp_body =~ ~s(<D:getetag>&quot;v1&quot;</D:getetag>)
      assert conn.resp_body =~ "<D:getcontenttype>text/calendar</D:getcontenttype>"
      # The invented one is named in a 404 propstat rather than refused.
      assert conn.resp_body =~ "<D:invented-by-a-client/>"
      assert conn.resp_body =~ "HTTP/1.1 404 Not Found"
    end

    test "getlastmodified is an HTTP-date, not ISO 8601", context do
      conn =
        DavPlug.call(
          request("PROPFIND", "/calendars/meeting.ics", "", [{"depth", "0"}]),
          context.options
        )

      assert conn.resp_body =~ "Tue, 15 Nov 1994 12:45:26 GMT"
    end

    test "Depth: infinity is refused rather than served", context do
      conn =
        DavPlug.call(
          request("PROPFIND", "/", "", [{"depth", "infinity"}]),
          context.options
        )

      assert conn.status == 403
    end

    test "a missing resource is 404, not an empty multistatus", context do
      conn = DavPlug.call(request("PROPFIND", "/nowhere", ""), context.options)

      assert conn.status == 404
    end

    test "a malformed body is 400", context do
      conn = DavPlug.call(request("PROPFIND", "/calendars", "<not xml"), context.options)

      assert conn.status == 400
    end
  end
end
