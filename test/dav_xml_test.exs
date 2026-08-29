defmodule Dav.XmlTest do
  use ExUnit.Case, async: true

  alias Dav.Xml

  doctest Dav.Xml

  defp build(responses), do: responses |> Xml.multistatus() |> IO.iodata_to_binary()

  describe "multistatus/1" do
    test "declares every namespace it uses, once, on the root" do
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 200 OK",
              [
                {{Xml.dav(), "displayname"}, "Calendars"},
                {{Xml.caldav(), "calendar-description"}, "Kim's diary"}
              ]}
           ]}
        ])

      assert xml =~ ~s(xmlns:D="DAV:")
      assert xml =~ ~s(xmlns:C="urn:ietf:params:xml:ns:caldav")
      # Once each, on the root element only.
      assert xml |> String.split(~s(xmlns:D=")) |> length() == 2
      assert xml =~ "<C:calendar-description>Kim&apos;s diary</C:calendar-description>"
    end

    test "a nil value writes an empty element, which is how 404 names what is missing" do
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 404 Not Found", [{{Xml.dav(), "getcontentlength"}, nil}]}
           ]}
        ])

      assert xml =~ "<D:getcontentlength/>"
      assert xml =~ "<D:status>HTTP/1.1 404 Not Found</D:status>"
    end

    test "structured values are written as child elements" do
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 200 OK",
              [{{Xml.dav(), "resourcetype"}, {:names, [{Xml.dav(), "collection"}]}}]}
           ]}
        ])

      assert xml =~ "<D:resourcetype><D:collection/></D:resourcetype>"
    end

    test "a structured value's own namespaces are declared, not just the property's" do
      # The bug this guards: a calendar's resourcetype carries
      # CALDAV:calendar inside a DAV: property. Collecting namespaces
      # from names alone emits an unbound prefix — malformed XML that
      # only fails at a real client.
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 200 OK",
              [
                {{Xml.dav(), "resourcetype"},
                 {:names, [{Xml.dav(), "collection"}, {Xml.caldav(), "calendar"}]}}
              ]}
           ]}
        ])

      assert xml =~ ~s(xmlns:C="urn:ietf:params:xml:ns:caldav")
      assert xml =~ "<C:calendar/>"
    end

    test "and the same for a report set naming an extension's report" do
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 200 OK",
              [
                {{Xml.dav(), "supported-report-set"},
                 Xml.supported_report_set([{Xml.caldav(), "calendar-query"}])}
              ]}
           ]}
        ])

      assert xml =~ ~s(xmlns:C="urn:ietf:params:xml:ns:caldav")
      assert xml =~ "<C:calendar-query/>"
    end

    test "one response may carry several statuses at once" do
      xml =
        build([
          {"/c/",
           [
             {"HTTP/1.1 200 OK", [{{Xml.dav(), "displayname"}, "C"}]},
             {"HTTP/1.1 404 Not Found", [{{Xml.dav(), "getetag"}, nil}]}
           ]}
        ])

      assert xml =~ "200 OK"
      assert xml =~ "404 Not Found"
      assert xml |> String.split("<D:propstat>") |> length() == 3
    end

    test "text is escaped so a display name cannot break the document" do
      xml = build([{"/c/", [{"HTTP/1.1 200 OK", [{{Xml.dav(), "displayname"}, "a & <b>"}]}]}])

      assert xml =~ "<D:displayname>a &amp; &lt;b&gt;</D:displayname>"
      refute xml =~ "<b>"
    end

    test "hrefs are escaped too" do
      xml = build([{"/c/a&b/", [{"HTTP/1.1 200 OK", []}]}])

      assert xml =~ "<D:href>/c/a&amp;b/</D:href>"
    end

    test "an unknown namespace gets a generated prefix that is still bound" do
      xml =
        build([
          {"/c/", [{"HTTP/1.1 200 OK", [{{"http://example.test/ns", "colour"}, "red"}]}]}
        ])

      assert xml =~ ~s(xmlns:n0="http://example.test/ns")
      assert xml =~ "<n0:colour>red</n0:colour>"
    end
  end
end
