defmodule Dav.CalDAVTester.VerifierTest do
  use ExUnit.Case, async: true

  alias Dav.CalDAVTester.Scenario.Verify
  alias Dav.CalDAVTester.Verifier

  # The whole conformance figure rests on these checks being upstream's
  # rather than a reasonable reading of them, so the cases below are
  # the ones `verifiers/xmlElementMatch.py` asserts on itself.
  @document """
  <D:test xmlns:D="DAV:">
    <D:a>A</D:a>
    <D:b>
      <D:c>C</D:c>
      <D:d>D</D:d>
    </D:b>
    <D:b>
      <D:c>C</D:c>
      <D:d>F</D:d>
    </D:b>
  </D:test>
  """

  defp matching(paths, kind \\ "exists") do
    conn = %Plug.Conn{status: 200, resp_body: @document}

    Verifier.run(%Verify{callback: "xmlElementMatch", args: %{kind => paths}}, conn)
  end

  describe "xmlElementMatch paths" do
    test "a plain path finds an element" do
      assert matching(["/{DAV:}test/{DAV:}a"]) == :passed
    end

    test "a path that names nothing does not" do
      assert {:failed, _why} = matching(["/{DAV:}test/{DAV:}z"])
    end

    test "a predicate matches on text" do
      assert matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]"]) == :passed
      assert {:failed, _why} = matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=X]"])
    end

    # Upstream's own two assertions. A predicate may be followed by
    # more path, and `../` steps out to the parent — which is how a
    # test on one child reaches its sibling. Without this the tail is
    # silently swallowed and every such check passes vacuously.
    test "a predicate may be followed by more path, through the parent" do
      assert matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]/../{DAV:}d[=D]"]) == :passed
    end

    test "and the continuation is what decides it" do
      assert {:failed, _why} = matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]/../{DAV:}d[=E]"])
    end

    # Two `b` elements share a `c` of C but differ in `d`. The walk has
    # to try each until one satisfies the whole path, rather than
    # settling on the first and reporting its answer.
    test "each candidate is tried, not only the first" do
      assert matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]/../{DAV:}d[=F]"]) == :passed
    end

    test "notexists is the same walk, answered the other way" do
      assert matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]/../{DAV:}d[=E]"], "notexists") == :passed

      assert {:failed, _why} =
               matching(["/{DAV:}test/{DAV:}b/{DAV:}c[=C]/../{DAV:}d[=D]"], "notexists")
    end
  end
end
