defmodule Dav.CalDAVTesterTest do
  @moduledoc """
  Apple's CalDAVTester scenarios, run against this server.

  This is the measurement the rest of the suite cannot give: the
  scenarios are what Apple Calendar actually does, and they check
  responses rather than merely reading requests.

  The baseline in `test/support/caldavtester/baseline.exs` records how
  many tests each scenario passes today. A change that lowers a count
  fails here, which is the point — the number is not allowed to drop
  quietly. A change that raises one also fails, and is fixed by
  regenerating the baseline:

      mix run priv/baseline.exs

  """

  use ExUnit.Case, async: true

  alias Dav.CalDAVTester.Features
  alias Dav.CalDAVTester.Runner
  alias Dav.CalDAVTester.Scenario
  alias Dav.CalDAVTester.ServerInfo

  @scenarios "rfc/conformance/caldavtester/scripts/tests/CalDAV/*.xml"
  @baseline "test/support/caldavtester/baseline.exs"

  setup_all do
    {:ok, substitutions} = ServerInfo.read()

    results =
      for path <- Path.wildcard(@scenarios),
          {:ok, scenario} = Scenario.read(path),
          into: %{} do
        outcomes = Enum.map(Runner.run(scenario, substitutions), &elem(&1, 2))
        {Path.basename(path), outcomes}
      end

    %{results: results, baseline: @baseline |> Code.eval_file() |> elem(0)}
  end

  test "no scenario passes fewer tests than it did", context do
    regressions =
      for {file, expected} <- context.baseline,
          actual = Enum.count(Map.get(context.results, file, []), &(&1 == :passed)),
          actual < expected,
          do: "  #{file}: #{actual}, was #{expected}"

    assert regressions == [],
           "these scenarios lost passing tests:\n" <> Enum.join(regressions, "\n")
  end

  test "no scenario passes more tests than the baseline records", context do
    # An improvement is good news and still fails, so that the recorded
    # figure is never stale — the README quotes it.
    improvements =
      for {file, outcomes} <- context.results,
          actual = Enum.count(outcomes, &(&1 == :passed)),
          actual > Map.get(context.baseline, file, 0),
          do: "  #{file}: #{actual}, baseline #{Map.get(context.baseline, file, 0)}"

    assert improvements == [],
           "these scenarios now pass more — run `mix run priv/baseline.exs`:\n" <>
             Enum.join(improvements, "\n")
  end

  test "the harness is actually running scenarios", context do
    # A wildcard that matched nothing, a feature list that gated
    # everything away, or a runner that skipped everything would make
    # the baseline tests pass while measuring nothing at all.
    assert map_size(context.results) == 162

    outcomes = context.results |> Map.values() |> List.flatten()
    assert length(outcomes) > 2000
    assert Enum.count(outcomes, &(&1 == :passed)) > 1000
  end

  test "the declared feature set is the one the server implements", context do
    # The denominator is set by what this server declares, so a feature
    # added here without the code behind it silently inflates the
    # conformance figure. `caldav` is the load-bearing claim.
    declared = Features.declared()

    assert MapSet.member?(declared, "caldav")
    # Declared because `Dav.Cal.Scheduling` implements it. Declaring a
    # feature that is not built is what turns this figure into a claim.
    assert MapSet.member?(declared, "implicit-scheduling")
    # Declared because `Dav.Web.Sync` implements RFC 6578, for
    # calendars and for the home.
    assert MapSet.member?(declared, "sync-report")
    assert MapSet.member?(declared, "sync-report-home")
    assert MapSet.size(declared) < 35
    assert map_size(context.results) == 162
  end

  test "an unimplemented check is never counted as a pass", context do
    # The measurement is only worth quoting if what it cannot verify is
    # excluded rather than assumed. Skips are the largest category and
    # must stay visibly separate from passes.
    outcomes = context.results |> Map.values() |> List.flatten()
    skipped = Enum.count(outcomes, &match?({:skipped, _reason}, &1))

    assert skipped > 0
    assert Enum.count(outcomes, &(&1 == :passed)) + skipped < length(outcomes)
  end
end
