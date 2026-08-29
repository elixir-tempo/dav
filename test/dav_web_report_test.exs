defmodule Dav.Web.ReportTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Dav.Test.EchoReport
  alias Dav.Test.MemoryStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

  @echo {"http://example.test/ns", "echo"}

  setup do
    resources = [
      %Resource{path: [], collection?: true, display_name: "Root"},
      %Resource{path: ["calendars"], collection?: true, display_name: "Calendars"}
    ]

    %{
      with_report:
        DavPlug.init(store: MemoryStore, context: resources, reports: [{@echo, EchoReport}]),
      without_report: DavPlug.init(store: MemoryStore, context: resources)
    }
  end

  defp report(path, body, options, headers \\ []) do
    conn =
      Enum.reduce(headers, conn("REPORT", path, body), fn {k, v}, conn ->
        put_req_header(conn, k, v)
      end)

    DavPlug.call(conn, options)
  end

  @echo_body ~s(<?xml version="1.0"?><e:echo xmlns:e="http://example.test/ns"/>)

  describe "dispatch" do
    test "a registered report runs and its responses become the multistatus", context do
      conn = report("/calendars", @echo_body, context.with_report, [{"depth", "1"}])

      assert conn.status == 207
      assert conn.resp_body =~ "<D:href>/calendars/</D:href>"
      assert conn.resp_body =~ "saw-depth>1<"
    end

    test "the handler is chosen by qualified name, not by prefix", context do
      # Same report, a different prefix, and a namespace declared inline.
      body = ~s(<?xml version="1.0"?><zz:echo xmlns:zz="http://example.test/ns"/>)
      conn = report("/calendars", body, context.with_report)

      assert conn.status == 207
    end

    test "an unregistered report is refused with the precondition that failed", context do
      conn = report("/calendars", @echo_body, context.without_report)

      assert conn.status == 403
      # Not a bare 403: the body names which rule was broken.
      assert conn.resp_body =~ "<D:error"
      assert conn.resp_body =~ "<D:supported-report/>"
    end

    test "a report the handler cannot parse is the client's error, not a refusal", context do
      body =
        ~s(<?xml version="1.0"?><e:echo xmlns:e="http://example.test/ns">make-it-fail</e:echo>)

      conn = report("/calendars", body, context.with_report)

      assert conn.status == 400
    end

    test "an empty body asks for nothing and is malformed", context do
      conn = report("/calendars", "", context.with_report)

      assert conn.status == 400
    end

    test "a report against a resource that is not there is 404", context do
      conn = report("/nowhere", @echo_body, context.with_report)

      assert conn.status == 404
    end
  end

  describe "DAV:supported-report-set" do
    test "lists what is registered, so a client can discover it", context do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:"><D:prop><D:supported-report-set/></D:prop></D:propfind>
      """

      conn =
        DavPlug.call(
          conn("PROPFIND", "/calendars", body) |> put_req_header("depth", "0"),
          context.with_report
        )

      assert conn.status == 207
      assert conn.resp_body =~ "<D:supported-report><D:report>"
      assert conn.resp_body =~ ":echo/>"
      assert conn.resp_body =~ "HTTP/1.1 200 OK"
    end

    test "is empty rather than absent when nothing is registered", context do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:"><D:prop><D:supported-report-set/></D:prop></D:propfind>
      """

      conn =
        DavPlug.call(
          conn("PROPFIND", "/calendars", body) |> put_req_header("depth", "0"),
          context.without_report
        )

      assert conn.resp_body =~ "<D:supported-report-set></D:supported-report-set>"
      refute conn.resp_body =~ "404 Not Found"
    end
  end

  describe "OPTIONS" do
    test "advertises REPORT now that it exists", context do
      conn = DavPlug.call(conn("OPTIONS", "/"), context.with_report)
      [allow] = get_resp_header(conn, "allow")

      assert allow =~ "REPORT"
    end
  end
end
