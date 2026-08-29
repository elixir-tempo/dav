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

  describe "what real clients send" do
    # Both of these were found by running the request bodies in
    # rfc/conformance/caldavtester/Resource through the parser. Neither
    # was caught by tests written from the specification, because both
    # are about how clients write XML rather than what the XML means.

    test "a default namespace declaration names elements as surely as a prefix" do
      # Apple's own fixtures use this form throughout. Reading only
      # prefixed names dropped the elements silently — a whole request
      # became malformed with nothing to point at.
      body = """
      <?xml version='1.0' encoding='UTF-8'?>
      <calendar-query xmlns='urn:ietf:params:xml:ns:caldav'>
        <prop xmlns='DAV:'><getetag/></prop>
      </calendar-query>
      """

      assert {:ok, root} = Xml.parse(body)
      assert root.name == {Xml.caldav(), "calendar-query"}
      assert [prop] = root.children
      assert prop.name == {Xml.dav(), "prop"}
      assert [getetag] = prop.children
      assert getetag.name == {Xml.dav(), "getetag"}
    end

    test "the same, for a REPORT's name" do
      body = ~s(<?xml version='1.0'?><calendar-query xmlns='urn:ietf:params:xml:ns:caldav'/>)

      assert Xml.report_name(body) == {:ok, {Xml.caldav(), "calendar-query"}}
    end

    test "and for PROPFIND's requested properties" do
      body = """
      <?xml version='1.0'?>
      <propfind xmlns='DAV:'><prop><getetag/><displayname/></prop></propfind>
      """

      assert {:ok, {:prop, names}} = Xml.parse_propfind(body)
      assert names == [{Xml.dav(), "getetag"}, {Xml.dav(), "displayname"}]
    end

    test "non-ASCII text does not make a document malformed" do
      # xmerl decodes by the document's own declaration, so the body
      # must reach it as bytes. As codepoints, an accented character
      # is reported as illegal and the whole request is refused.
      body = """
      <?xml version="1.0" encoding="utf-8" ?>
      <D:propfind xmlns:D="DAV:"><D:prop><D:displayname>té</D:displayname></D:prop></D:propfind>
      """

      assert {:ok, root} = Xml.parse(body)
      assert [prop] = root.children
      assert [displayname] = prop.children
      assert displayname.text == "té"
    end

    test "and survives a round trip through PROPPATCH" do
      body = """
      <?xml version="1.0" encoding="utf-8" ?>
      <D:propertyupdate xmlns:D="DAV:" xmlns:x="http://example.test/">
        <D:set><D:prop><x:ville>Genève</x:ville></D:prop></D:set>
      </D:propertyupdate>
      """

      assert {:ok, [{:set, {"http://example.test/", "ville"}, "Genève"}]} =
               Xml.parse_proppatch(body)
    end
  end

  describe "href-valued properties" do
    test "each URL becomes a DAV:href child" do
      # A property that points at another resource writes its value as
      # `DAV:href`. A bare string would be read as text, and a client
      # looking for the href child would find none.
      document =
        Xml.multistatus([
          {"/p/",
           [{"HTTP/1.1 200 OK", [{{Xml.caldav(), "calendar-home-set"}, {:hrefs, ["/c/"]}}]}]}
        ])
        |> IO.iodata_to_binary()

      assert document =~ "calendar-home-set"
      assert document =~ "<D:href>/c/</D:href>"
    end

    test "several URLs each get their own href" do
      document =
        Xml.multistatus([
          {"/p/",
           [
             {"HTTP/1.1 200 OK",
              [
                {{Xml.caldav(), "calendar-user-address-set"},
                 {:hrefs, ["mailto:a@x", "mailto:b@x"]}}
              ]}
           ]}
        ])
        |> IO.iodata_to_binary()

      assert document =~ "<D:href>mailto:a@x</D:href><D:href>mailto:b@x</D:href>"
    end
  end

  describe "PROPPATCH values" do
    test "an href-valued property keeps its structure" do
      # Flattening `<D:href>` to text stores something that cannot be
      # read back: the client set an href and would be handed a string.
      body = """
      <?xml version="1.0"?>
      <D:propertyupdate xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:set><D:prop>
          <C:schedule-default-calendar-URL><D:href>/calendars/work/</D:href></C:schedule-default-calendar-URL>
        </D:prop></D:set>
      </D:propertyupdate>
      """

      assert {:ok, [{:set, {_namespace, "schedule-default-calendar-URL"}, value}]} =
               Xml.parse_proppatch(body)

      assert value == {:hrefs, ["/calendars/work/"]}
    end

    test "a text-valued property is still text" do
      body = """
      <?xml version="1.0"?>
      <D:propertyupdate xmlns:D="DAV:">
        <D:set><D:prop><D:displayname>Work</D:displayname></D:prop></D:set>
      </D:propertyupdate>
      """

      assert {:ok, [{:set, {"DAV:", "displayname"}, "Work"}]} = Xml.parse_proppatch(body)
    end

    test "a property holding empty elements keeps their names" do
      body = """
      <?xml version="1.0"?>
      <D:propertyupdate xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:set><D:prop><C:schedule-calendar-transp><C:opaque/></C:schedule-calendar-transp></D:prop></D:set>
      </D:propertyupdate>
      """

      assert {:ok, [{:set, _name, {:names, [{_ns, "opaque"}]}}]} = Xml.parse_proppatch(body)
    end
  end
end
