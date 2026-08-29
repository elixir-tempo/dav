alias Dav.CalDAVTester.{Scenario, Runner, ServerInfo}
{:ok, subs} = ServerInfo.read()
start = System.monotonic_time(:millisecond)

rows =
  "rfc/conformance/caldavtester/scripts/tests/CalDAV/*.xml"
  |> Path.wildcard()
  |> Enum.map(fn path ->
    {:ok, sc} = Scenario.read(path)
    outcomes = Enum.map(Runner.run(sc, subs), fn {_, _, o} -> o end)
    {Path.basename(path), Enum.count(outcomes, &(&1 == :passed))}
  end)
  |> Enum.filter(fn {_, n} -> n > 0 end)
  |> Enum.sort()

elapsed = System.monotonic_time(:millisecond) - start

File.write!(
  "test/support/caldavtester/baseline.exs",
  "# Passing CalDAVTester tests per scenario, as measured by\n" <>
    "# `Dav.CalDAVTester.Runner`. Regenerate with `mix run priv/baseline.exs`\n" <>
    "# after a change that legitimately improves or reduces coverage.\n" <>
    "%{\n" <> Enum.map_join(rows, "", fn {f, n} -> "  #{inspect(f)} => #{n},\n" end) <> "}\n"
)

IO.puts(
  "#{length(rows)} scenarios with passes, #{Enum.sum(Enum.map(rows, &elem(&1, 1)))} passing tests, #{elapsed}ms"
)
