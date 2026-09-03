defmodule Dav.Cal.BulkTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Plug.Conn

  doctest Dav.Cal.Bulk

  setup do
    agent =
      SchedulingStore.start(
        [
          %Resource{path: [], collection?: true},
          %Resource{path: ["alice"], collection?: true, owner: "/p/alice/"},
          %Resource{
            path: ["alice", "work"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/p/alice/"
          },
          %Resource{path: ["alice", "notes"], collection?: true, owner: "/p/alice/"}
        ],
        %{"mailto:alice@example.com" => ["alice"]}
      )

    options =
      DavPlug.init(
        store: SchedulingStore,
        context: agent,
        methods: [{"POST", Cal.Post}],
        validators: [Cal.Object],
        hooks: [Cal.Bulk, Cal.Scheduling]
      )

    %{options: options}
  end

  defp event(uid, summary, zone \\ "Etc/GMT+5") do
    """
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART;TZID=#{zone}:20260901T180000
    DURATION:PT1H
    DTSTAMP:20260101T000000Z
    SUMMARY:#{summary}
    END:VEVENT
    """
    |> String.trim_trailing()
  end

  defp zone(identifier) do
    """
    BEGIN:VTIMEZONE
    TZID:#{identifier}
    BEGIN:STANDARD
    DTSTART:18000101T000000
    RDATE:18000101T000000
    TZNAME:#{identifier}
    TZOFFSETFROM:-0500
    TZOFFSETTO:-0500
    END:STANDARD
    END:VTIMEZONE
    """
    |> String.trim_trailing()
  end

  defp calendar(parts) do
    (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN"] ++ parts ++ ["END:VCALENDAR"])
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp post(body, options, headers \\ []) do
    Enum.reduce(headers, conn("POST", "/alice/work/", body), fn {name, value}, conn ->
      Conn.put_req_header(conn, name, value)
    end)
    |> DavPlug.call(options)
  end

  defp multiput(inner, options, headers \\ []) do
    body = """
    <?xml version="1.0" encoding="utf-8"?>
    <MM:multiput xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:MM="http://me.com/_namespace/">#{inner}</MM:multiput>
    """

    post(body, options, headers)
  end

  defp hrefs(conn) do
    Regex.scan(~r|<[^:]+:href>([^<]+)</[^:]+:href>|, conn.resp_body, capture: :all_but_first)
    |> List.flatten()
  end

  defp get(path, options) do
    DavPlug.call(conn("GET", path), options)
  end

  defp propfind(path, property, options) do
    body =
      ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:" xmlns:MM="http://me.com/_namespace/"><D:prop>#{property}</D:prop></D:propfind>)

    conn("PROPFIND", path, body)
    |> Conn.put_req_header("depth", "0")
    |> DavPlug.call(options)
  end

  describe "the bulk-requests property" do
    test "a calendar advertises both forms", context do
      listing = propfind("/alice/work", "<MM:bulk-requests/>", context.options)

      assert listing.resp_body =~ "bulk-requests"
      assert listing.resp_body =~ "simple"
      assert listing.resp_body =~ "crud"
    end

    # The property is how a client decides where a bulk `POST` may go.
    # Advertising it on a plain collection would send one to a place
    # that cannot answer it.
    test "an ordinary collection does not", context do
      listing = propfind("/alice/notes", "<MM:bulk-requests/>", context.options)

      refute listing.resp_body =~ "bulk-requests><"
      assert listing.resp_body =~ "404"
    end
  end

  describe "the simple form" do
    test "one calendar of several components becomes one resource each", context do
      body =
        calendar([
          zone("Etc/GMT+5"),
          zone("Etc/GMT+8"),
          event("one", "first"),
          event("two", "second", "Etc/GMT+8")
        ])

      conn = post(body, context.options)

      assert conn.status == 207
      assert [first, second] = hrefs(conn)
      assert get(first, context.options).resp_body =~ "SUMMARY:first"
      assert get(second, context.options).resp_body =~ "SUMMARY:second"
    end

    # A resource carrying a definition for a zone none of its own
    # components names is calendar data about nothing.
    test "each resource keeps only the zones it references", context do
      body =
        calendar([
          zone("Etc/GMT+5"),
          zone("Etc/GMT+8"),
          event("one", "first"),
          event("two", "second", "Etc/GMT+8")
        ])

      [first, _second] = context.options |> then(&post(body, &1)) |> hrefs()

      stored = get(first, context.options).resp_body

      assert stored =~ "TZID:Etc/GMT+5"
      refute stored =~ "TZID:Etc/GMT+8"
    end

    test "the response names each stored resource by its UID", context do
      conn = post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options)

      assert conn.resp_body =~ "uid>one<"
      assert conn.resp_body =~ "getetag"
    end

    # The client never said which resource it meant, so a `UID` the
    # collection already holds cannot be read as an edit.
    test "a UID already in the collection is refused, and the rest are not", context do
      post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options)

      conn =
        post(
          calendar([zone("Etc/GMT+5"), event("one", "again"), event("three", "third")]),
          context.options
        )

      assert conn.resp_body =~ "403"
      assert conn.resp_body =~ "no-uid-conflict"
      assert conn.resp_body =~ "uid>three<"
    end

    test "the stored data is not returned unless it was asked for", context do
      conn = post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options)

      refute conn.resp_body =~ "calendar-data"
    end
  end

  describe "the CRUD form" do
    test "a resource without an href is created at a name the server picks", context do
      body = calendar([zone("Etc/GMT+5"), event("one", "first")])

      conn =
        multiput(
          "<MM:resource><D:set><C:calendar-data><![CDATA[#{body}]]></C:calendar-data></D:set></MM:resource>",
          context.options
        )

      assert conn.status == 207
      assert [href] = hrefs(conn)
      assert get(href, context.options).resp_body =~ "SUMMARY:first"
    end

    test "a resource with an href replaces what is there", context do
      created =
        multiput(
          "<MM:resource><D:set><D:prop><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("one", "first")])}]]></C:calendar-data></D:prop></D:set></MM:resource>",
          context.options
        )

      [href] = hrefs(created)

      updated =
        multiput(
          "<MM:resource><D:href>#{href}</D:href><D:set><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("one", "revised")])}]]></C:calendar-data></D:set></MM:resource>",
          context.options
        )

      assert hrefs(updated) == [href]
      assert get(href, context.options).resp_body =~ "SUMMARY:revised"
    end

    test "MM:delete removes the resource it names", context do
      created =
        multiput(
          "<MM:resource><D:set><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("one", "first")])}]]></C:calendar-data></D:set></MM:resource>",
          context.options
        )

      [href] = hrefs(created)

      removed =
        multiput(
          "<MM:resource><D:href>#{href}</D:href><MM:delete/></MM:resource>",
          context.options
        )

      assert removed.status == 207
      assert get(href, context.options).status == 404
    end

    # One stale entry refuses one entry. Refusing the request would
    # make a client re-send everything it had already got right.
    test "a stale MM:if-match refuses only its own entry", context do
      created =
        multiput(
          "<MM:resource><D:set><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("one", "first")])}]]></C:calendar-data></D:set></MM:resource>",
          context.options
        )

      [href] = hrefs(created)

      conn =
        multiput(
          """
          <MM:resource><D:href>#{href}</D:href>
          <MM:if-match><D:getetag>"not-the-one"</D:getetag></MM:if-match>
          <D:set><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("one", "revised")])}]]></C:calendar-data></D:set>
          </MM:resource>
          <MM:resource><D:set><C:calendar-data><![CDATA[#{calendar([zone("Etc/GMT+5"), event("two", "second")])}]]></C:calendar-data></D:set></MM:resource>
          """,
          context.options
        )

      assert conn.resp_body =~ "412"
      assert conn.resp_body =~ "uid>two<"
      assert get(href, context.options).resp_body =~ "SUMMARY:first"
    end

    # A resource that neither deletes nor sets anything asks for
    # nothing, and writing its emptiness would leave a calendar object
    # with no body in the collection.
    test "a resource carrying no calendar data is refused", context do
      conn = multiput("<MM:resource><D:set><D:prop/></D:set></MM:resource>", context.options)

      assert conn.resp_body =~ "403"
      refute conn.resp_body =~ "getetag"
    end

    test "an href outside the calendar is refused", context do
      conn =
        multiput(
          "<MM:resource><D:href>/alice/notes/1.ics</D:href><MM:delete/></MM:resource>",
          context.options
        )

      assert conn.resp_body =~ "403"
    end
  end

  describe "return-changed-data" do
    # The point of asking is to learn what the server did to the data.
    # A write it left alone has nothing to report, and sending the
    # object back would double the response for no news.
    test "unchanged data is not sent back", context do
      conn =
        post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options, [
          {"x-mobileme-dav-options", "return-changed-data"}
        ])

      refute conn.resp_body =~ "calendar-data"
    end
  end

  describe "the ctag condition" do
    test "a stale ctag refuses the whole request", context do
      conn =
        post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options, [
          {"if", "<http://me.com/_namespace/ctag/nonsense>"}
        ])

      assert conn.status == 412
      assert hrefs(conn) == []
    end

    test "the current ctag lets it through, and the answer carries the next one", context do
      listing =
        propfind(
          "/alice/work",
          ~s(<CS:getctag xmlns:CS="http://calendarserver.org/ns/"/>),
          context.options
        )

      [ctag] =
        Regex.scan(~r|getctag>([^<]+)</|, listing.resp_body, capture: :all_but_first)
        |> List.flatten()

      conn =
        post(calendar([zone("Etc/GMT+5"), event("one", "first")]), context.options, [
          {"if", "<http://me.com/_namespace/ctag/#{ctag}>"}
        ])

      assert conn.status == 207
      assert [moved] = Conn.get_resp_header(conn, "ctag")
      assert moved != ctag
    end
  end
end
