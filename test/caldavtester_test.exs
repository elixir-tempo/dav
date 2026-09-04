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
  adopting the new figures:

      DAV_BASELINE=1 mix test

  which rewrites the baseline from this same run and prints what
  moved, along with the classified conformance position. `DAV_REPORT=1`
  prints both without rewriting anything. The corpus takes minutes to
  run, so it is run once here and every reading is taken from that one
  run — see `Dav.CalDAVTester.Corpus`.

  """

  use ExUnit.Case, async: true

  alias Dav.CalDAVTester.Corpus
  alias Dav.CalDAVTester.Features

  setup_all do
    results = Corpus.run()
    baseline = Corpus.baseline()

    recording? = System.get_env("DAV_BASELINE") == "1"
    if recording? or System.get_env("DAV_REPORT") == "1", do: report(results, baseline)
    if recording?, do: Corpus.record(results)

    %{results: Corpus.outcomes(results), baseline: baseline, recording?: recording?}
  end

  defp report(results, baseline) do
    moved =
      Enum.map_join(Corpus.drift(results, baseline), "", fn {file, now, was} ->
        "  #{file}: #{now}, was #{was}\n"
      end)

    IO.puts(
      "\nAgainst the recorded baseline\n" <> if(moved == "", do: "  nothing moved\n", else: moved)
    )

    IO.puts(Corpus.headline(results))
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
    # figure is never stale — the README quotes it. The exception is the
    # run that is adopting the new figures, which has just written them.
    improvements =
      for {file, outcomes} <- context.results,
          actual = Enum.count(outcomes, &(&1 == :passed)),
          actual > Map.get(context.baseline, file, 0),
          do: "  #{file}: #{actual}, baseline #{Map.get(context.baseline, file, 0)}"

    assert context.recording? or improvements == [],
           "these scenarios now pass more — run `DAV_BASELINE=1 mix test`:\n" <>
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
    # Declared because `Dav.Cal.TimezoneService` implements RFC 7808
    # and `Dav.Cal.TimezoneQuery` the older dialect beside it, both
    # reading the catalogue in `Dav.Cal.Zones`.
    assert MapSet.member?(declared, "timezone-std-service")
    assert MapSet.member?(declared, "timezone-service")
    # Declared because `Dav.Cal.Travel` folds the journey either side
    # of an event into its busy time, which is what the feature names.
    # `sharing-traveltime.xml` still fails, for a different missing
    # thing — per-user data on a shared calendar — and says so in
    # `classification.exs` rather than by withholding this.
    assert MapSet.member?(declared, "travel-time-busy")
    # A ceiling, not a target: the count rises only when a feature is
    # built, and raising it is the moment to check that it was.
    assert MapSet.size(declared) < 55
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
