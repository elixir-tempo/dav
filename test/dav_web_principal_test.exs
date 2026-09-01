defmodule Dav.Web.PrincipalTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Test.WritableStore
  alias Dav.Web.Acl
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Principal
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn

  doctest Dav.Web.Acl
  doctest Dav.Web.Principal

  setup do
    kip = "/principals/kip/"
    sam = "/principals/sam/"

    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["principals"], collection?: true},
        %Resource{
          path: ["principals", "kip"],
          collection?: true,
          types: [Acl.principal()],
          owner: kip,
          display_name: "Kip Cole"
        },
        %Resource{
          path: ["principals", "sam"],
          collection?: true,
          types: [Acl.principal()],
          owner: sam,
          display_name: "Sam Jones"
        },
        %Resource{path: ["home"], collection?: true, owner: kip},
        %Resource{path: ["home", "calendar"], collection?: true, owner: kip}
      ])

    options =
      DavPlug.init(
        store: WritableStore,
        context: agent,
        principal: "/principals/kip/",
        reports: [
          {{Xml.dav(), "principal-match"}, Principal.Match},
          {{Xml.dav(), "principal-property-search"}, Principal.PropertySearch},
          {{Xml.dav(), "principal-search-property-set"}, Principal.SearchPropertySet},
          {{Xml.dav(), "acl-principal-prop-set"}, Principal.AclPrincipalPropSet},
          {{Xml.dav(), "expand-property"}, Principal.ExpandProperty}
        ]
      )

    %{options: options}
  end

  defp report(path, body, options, depth \\ "0") do
    conn("REPORT", path, body)
    |> Conn.put_req_header("depth", depth)
    |> DavPlug.call(options)
  end

  describe "access control properties" do
    test "a resource reports who may do what here", context do
      body =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:current-user-privilege-set/><D:owner/></D:prop></D:propfind>)

      conn =
        conn("PROPFIND", "/home/calendar", body)
        |> Conn.put_req_header("depth", "0")
        |> DavPlug.call(context.options)

      # Without this a client has to assume it may write, and finds out
      # otherwise by failing.
      assert conn.resp_body =~ "<D:privilege><D:write/></D:privilege>"
      assert conn.resp_body =~ "<D:href>/principals/kip/</D:href>"
    end

    test "an unauthenticated request says so", context do
      # "Who am I" is a fact about the request, not the resource: the
      # same collection answers differently to different callers.
      anonymous = %{context.options | principal: nil}

      body =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/></D:prop></D:propfind>)

      conn =
        conn("PROPFIND", "/principals", body)
        |> Conn.put_req_header("depth", "0")
        |> DavPlug.call(anonymous)

      assert conn.resp_body =~ "<D:unauthenticated/>"
    end

    test "the same resource answers differently to different callers", context do
      body =
        ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:current-user-principal/></D:prop></D:propfind>)

      ask = fn options ->
        conn("PROPFIND", "/home/calendar", body)
        |> Conn.put_req_header("depth", "0")
        |> DavPlug.call(options)
        |> Map.fetch!(:resp_body)
      end

      # Deriving it from the resource's owner instead would tell every
      # caller they own whatever they are looking at.
      assert ask.(context.options) =~ "/principals/kip/"
      assert ask.(%{context.options | principal: "/principals/sam/"}) =~ "/principals/sam/"
    end
  end

  describe "principal-property-search" do
    test "finds a principal by a substring of its name", context do
      body = """
      <?xml version="1.0"?>
      <D:principal-property-search xmlns:D="DAV:">
        <D:property-search><D:prop><D:displayname/></D:prop><D:match>kip</D:match></D:property-search>
        <D:prop><D:displayname/></D:prop>
      </D:principal-property-search>
      """

      conn = report("/principals", body, context.options)

      # Case-insensitive substring is what a client typing into a name
      # field expects.
      assert conn.resp_body =~ "Kip Cole"
      refute conn.resp_body =~ "Sam Jones"
    end

    test "a search matching nothing returns no responses", context do
      body = """
      <?xml version="1.0"?>
      <D:principal-property-search xmlns:D="DAV:">
        <D:property-search><D:prop><D:displayname/></D:prop><D:match>nobody</D:match></D:property-search>
        <D:prop><D:displayname/></D:prop>
      </D:principal-property-search>
      """

      refute report("/principals", body, context.options).resp_body =~ "<D:response>"
    end
  end

  # RFC 3744 section 9.3: `DAV:self` matches the principals that *are*
  # the current user — and groups they belong to — not everyone here.
  test "principal-match with DAV:self returns the caller's principals", context do
    body =
      ~s(<?xml version="1.0"?><D:principal-match xmlns:D="DAV:"><D:self/><D:prop><D:displayname/></D:prop></D:principal-match>)

    conn = report("/principals", body, context.options)

    assert conn.resp_body =~ "Kip Cole"
    refute conn.resp_body =~ "Sam Jones"
  end

  test "principal-search-property-set says what may be searched", context do
    body = ~s(<?xml version="1.0"?><D:principal-search-property-set xmlns:D="DAV:"/>)
    conn = report("/principals", body, context.options)

    # A client that cannot ask this has to hard-code a guess.
    assert conn.status == 200
    assert conn.resp_body =~ "displayname"
    assert conn.resp_body =~ "calendar-user-address-set"
  end

  test "acl-principal-prop-set names the principals in an ACL", context do
    body =
      ~s(<?xml version="1.0"?><D:acl-principal-prop-set xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:acl-principal-prop-set>)

    conn = report("/home/calendar", body, context.options)

    # Turning an ACL of URLs into names a person can read is the
    # report's stated purpose.
    assert conn.resp_body =~ "Kip Cole"
  end

  test "acl-principal-prop-set requires Depth 0", context do
    body =
      ~s(<?xml version="1.0"?><D:acl-principal-prop-set xmlns:D="DAV:"><D:prop><D:displayname/></D:prop></D:acl-principal-prop-set>)

    assert report("/home/calendar", body, context.options, "1").status == 400
  end

  describe "expand-property" do
    test "returns the referenced resource inline", context do
      body = """
      <?xml version="1.0"?>
      <D:expand-property xmlns:D="DAV:">
        <D:property name="current-user-principal" namespace="DAV:">
          <D:property name="displayname" namespace="DAV:"/>
        </D:property>
      </D:expand-property>
      """

      conn = report("/home/calendar", body, context.options)

      # The point is saving the second round trip: the name comes back
      # inside the property that pointed at it.
      assert conn.resp_body =~ "Kip Cole"
      assert conn.resp_body =~ "current-user-principal"
    end

    test "a property the resource does not have is reported missing", context do
      body = """
      <?xml version="1.0"?>
      <D:expand-property xmlns:D="DAV:">
        <D:property name="nonesuch" namespace="DAV:"/>
      </D:expand-property>
      """

      conn = report("/home/calendar", body, context.options)

      # "No such property" and "a property whose references expanded to
      # nothing" are different answers.
      assert conn.resp_body =~ "404 Not Found"
    end

    test "requires Depth 0", context do
      body = ~s(<?xml version="1.0"?><D:expand-property xmlns:D="DAV:"/>)

      assert report("/home/calendar", body, context.options, "1").status == 400
    end
  end
end
