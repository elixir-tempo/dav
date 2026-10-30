defmodule Dav.CalDAVTester.ServerInfoTest do
  use ExUnit.Case, async: true

  # The examples are the claims both drivers rest on: what a `$key:`
  # expands to, and what the deployment tells CalDAVTester about
  # itself. Unrun, they were documentation nobody had checked.
  doctest Dav.CalDAVTester.ServerInfo
end
