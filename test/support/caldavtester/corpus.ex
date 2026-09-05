defmodule Dav.CalDAVTester.Corpus do
  @moduledoc """
  One run of the whole CalDAVTester corpus, and everything read from it.

  Running the 162 scenarios takes minutes, and for a long while the
  close-out ran them four times over: once to diff against the
  baseline, once to rewrite it, once to print the classified headline,
  and once more inside the regression test. The four runs measured the
  same thing and differed only in what they printed.

  So the run lives here and the readings are functions of its result.
  `run/0` produces it; `outcomes/1`, `counts/1`, `drift/2`,
  `record/1` and `headline/1` read it. `Dav.CalDAVTesterTest` calls
  `run/0` once, which makes `mix test` the only pass anyone needs:

      DAV_BASELINE=1 mix test

  regenerates `test/support/caldavtester/baseline.exs` and prints the
  per-file drift and the classified position, while still asserting
  that no scenario lost ground.

  """

  alias Dav.CalDAVTester.Runner
  alias Dav.CalDAVTester.Scenario
  alias Dav.CalDAVTester.ServerInfo

  @scenarios "rfc/conformance/caldavtester/scripts/tests/CalDAV/*.xml"
  @baseline "test/support/caldavtester/baseline.exs"
  @classification "test/support/caldavtester/classification.exs"
  @unclassified {:unclassified, "no entry — triage it"}

  @typedoc "Every test the corpus ran, keyed by scenario file name."
  @type results :: %{String.t() => [{String.t(), String.t(), Runner.outcome()}]}

  @doc """
  Runs every CalDAVTester scenario against this server.

  ### Returns

  * A map from scenario file name to the list of `{suite, test,
    outcome}` triples that scenario produced.

  """
  @spec run() :: results()
  def run do
    {:ok, substitutions} = ServerInfo.read()

    for path <- Path.wildcard(@scenarios), into: %{} do
      {:ok, scenario} = Scenario.read(path)
      {Path.basename(path), Runner.run(scenario, substitutions)}
    end
  end

  @doc """
  Reduces a run to the outcomes alone, dropping the test names.

  ### Arguments

  * `results` is the map returned by `run/0`.

  ### Returns

  * A map from scenario file name to its list of outcomes.

  """
  @spec outcomes(results()) :: %{String.t() => [Runner.outcome()]}
  def outcomes(results) do
    Map.new(results, fn {file, triples} -> {file, Enum.map(triples, &elem(&1, 2))} end)
  end

  @doc """
  Counts the passing tests in each scenario.

  ### Arguments

  * `results` is the map returned by `run/0`.

  ### Returns

  * A map from scenario file name to the number of tests it passed.

  """
  @spec counts(results()) :: %{String.t() => non_neg_integer()}
  def counts(results) do
    Map.new(outcomes(results), fn {file, outcomes} ->
      {file, Enum.count(outcomes, &(&1 == :passed))}
    end)
  end

  @doc """
  Reads the recorded baseline.

  ### Returns

  * A map from scenario file name to the number of tests it passed
    when the baseline was last written.

  """
  @spec baseline() :: %{String.t() => non_neg_integer()}
  def baseline, do: @baseline |> Code.eval_file() |> elem(0)

  @doc """
  Reports every scenario whose count moved.

  ### Arguments

  * `results` is the map returned by `run/0`.

  * `baseline` is the recorded map, as returned by `baseline/0`.

  ### Returns

  * A list of `{file, now, was}` triples, sorted by file name, for the
    scenarios that differ. Empty when nothing moved.

  """
  @spec drift(results(), %{String.t() => non_neg_integer()}) ::
          [{String.t(), non_neg_integer(), non_neg_integer()}]
  def drift(results, baseline) do
    counts = counts(results)

    for file <-
          counts |> Map.keys() |> Enum.concat(Map.keys(baseline)) |> Enum.uniq() |> Enum.sort(),
        now = Map.get(counts, file, 0),
        was = Map.get(baseline, file, 0),
        now != was,
        do: {file, now, was}
  end

  @doc """
  Rewrites the recorded baseline from a run.

  Written through the formatter, because the file it writes is checked
  by `mix format --check-formatted` like any other. Every scenario is
  recorded, including those with nothing passing yet: a file left out
  because it scored zero is a file whose first success — and whose
  later regression back to zero — nobody would see.

  ### Arguments

  * `results` is the map returned by `run/0`.

  ### Returns

  * The map of counts that was written.

  """
  @spec record(results()) :: %{String.t() => non_neg_integer()}
  def record(results) do
    counts = counts(results)
    rows = Enum.sort(counts)

    contents =
      ("# Passing CalDAVTester tests per scenario, as measured by\n" <>
         "# `Dav.CalDAVTester.Runner`. Regenerate with `DAV_BASELINE=1 mix test`\n" <>
         "# after a change that legitimately improves or reduces coverage.\n" <>
         "%{\n" <> Enum.map_join(rows, "", fn {f, n} -> "  #{inspect(f)} => #{n},\n" end) <> "}\n")
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    File.write!(@baseline, contents <> "\n")

    counts
  end

  @doc """
  The classified conformance position, as printable text.

  Every failing test is assigned a class from
  `test/support/caldavtester/classification.exs`: `rfc` for defects
  against RFC-required behaviour, `apple` for CalendarServer behaviour
  beyond the RFCs, `incidental` for expectations that cannot be met on
  principle, and `unclassified` for anything with no entry. The
  headline number is the `rfc` count, and `unclassified` is the queue
  that has to be emptied before a batch closes.

  ### Arguments

  * `results` is the map returned by `run/0`.

  ### Returns

  * A binary, ready for `IO.puts/1`, holding the four counts and a
    breakdown of the unclassified and RFC failures.

  """
  @spec headline(results()) :: String.t()
  def headline(results) do
    classes = @classification |> Code.eval_file() |> elem(0)

    failures =
      for {file, triples} <- results,
          {suite, test, outcome} <- triples,
          outcome != :passed do
        {class, why} =
          Map.get(classes, {file, suite}) || Map.get(classes, {file, nil}) || @unclassified

        %{file: file, suite: suite, test: test, class: class, why: why}
      end

    by_class = Enum.group_by(failures, & &1.class)
    count = &length(Map.get(by_class, &1, []))

    outcomes = results |> outcomes() |> Map.values() |> List.flatten()
    passed = Enum.count(outcomes, &(&1 == :passed))
    skipped = Enum.count(outcomes, &match?({:skipped, _reason}, &1))

    """

    CalDAV conformance, classified
    ==============================
    RFC-required failing:  #{count.(:rfc)}   <- the defect queue
    Apple/interop failing: #{count.(:apple)}   <- the interop queue
    Incidental (cited):    #{count.(:incidental)}
    Unclassified:          #{count.(:unclassified)}

    #{length(outcomes)} tests: #{passed} passed, \
    #{length(outcomes) - passed - skipped} failed, #{skipped} skipped \
    (the figures the README quotes)
    """ <>
      Enum.map_join(
        [:unclassified, :rfc, :apple],
        "",
        &breakdown(&1, Map.get(by_class, &1, []))
      )
  end

  # `:apple` is listed as well as the two queues that must stay empty.
  # A class that is only ever counted is a class nobody checks: this
  # file's own summary claimed for months that fourteen of the Apple
  # failures were `sharing-quota.xml`, which is cited `:incidental`
  # and had never been in the queue at all. A tally is not evidence.
  defp breakdown(_class, []), do: ""

  defp breakdown(class, listed) do
    rows =
      listed
      |> Enum.group_by(&{&1.file, &1.suite, &1.why})
      |> Enum.sort()
      |> Enum.map_join("", fn {{file, suite, why}, tests} ->
        names = Enum.map_join(tests, ",", & &1.test)
        tally = String.pad_leading(to_string(length(tests)), 3)

        "#{tally}  #{file} :: #{suite} [#{names}]\n       #{why}\n"
      end)

    "\n-- #{class} --\n" <> rows
  end
end
