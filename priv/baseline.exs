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

path = "test/support/caldavtester/baseline.exs"

# Written through the formatter, because the file it writes is
# checked by `mix format --check-formatted` like any other. Emitting
# it by hand left a trailing comma the formatter then removed, so
# every regeneration failed the format gate until someone reformatted
# it by hand.
contents =
  ("# Passing CalDAVTester tests per scenario, as measured by\n" <>
     "# `Dav.CalDAVTester.Runner`. Regenerate with `mix run priv/baseline.exs`\n" <>
     "# after a change that legitimately improves or reduces coverage.\n" <>
     "%{\n" <> Enum.map_join(rows, "", fn {f, n} -> "  #{inspect(f)} => #{n},\n" end) <> "}\n")
  |> Code.format_string!()
  |> IO.iodata_to_binary()

File.write!(path, contents <> "\n")

IO.puts(
  "#{length(rows)} scenarios with passes, #{Enum.sum(Enum.map(rows, &elem(&1, 1)))} passing tests, #{elapsed}ms"
)
