# The conformance position, classified. Run with:
#
#     MIX_ENV=test mix run priv/conformance.exs
#
# Every failing CalDAVTester test is assigned a class from
# `test/support/caldavtester/classification.exs`:
#
#   rfc          defects against RFC-required behaviour — the first queue
#   apple        CalendarServer/Apple behaviour beyond the RFCs — the
#                interop queue
#   incidental   expectations that cannot be met on principle, cited
#   unclassified new failures needing triage
#
# The headline number is the `rfc` count.
alias Dav.CalDAVTester.{Scenario, Runner, ServerInfo}

{:ok, subs} = ServerInfo.read()

classes =
  "test/support/caldavtester/classification.exs" |> Code.eval_file() |> elem(0)

classify = fn file, suite ->
  Map.get(classes, {file, suite}) || Map.get(classes, {file, nil}) ||
    {:unclassified, "no entry — triage it"}
end

failures =
  for path <- Path.wildcard("rfc/conformance/caldavtester/scripts/tests/CalDAV/*.xml"),
      {:ok, scenario} = Scenario.read(path),
      {suite, test, outcome} <- Runner.run(scenario, subs),
      outcome != :passed do
    file = Path.basename(path)
    {class, why} = classify.(file, suite)
    %{file: file, suite: suite, test: test, class: class, why: why}
  end

by_class = Enum.group_by(failures, & &1.class)
count = fn class -> length(Map.get(by_class, class, [])) end

IO.puts("""

CalDAV conformance, classified
==============================
RFC-required failing:  #{count.(:rfc)}   <- the defect queue
Apple/interop failing: #{count.(:apple)}   <- the interop queue
Incidental (cited):    #{count.(:incidental)}
Unclassified:          #{count.(:unclassified)}
""")

for class <- [:unclassified, :rfc] do
  case Map.get(by_class, class, []) do
    [] ->
      :ok

    listed ->
      IO.puts("-- #{class} --")

      listed
      |> Enum.group_by(&{&1.file, &1.suite, &1.why})
      |> Enum.sort()
      |> Enum.each(fn {{file, suite, why}, tests} ->
        names = tests |> Enum.map(& &1.test) |> Enum.join(",")

        IO.puts(
          "#{String.pad_leading(to_string(length(tests)), 3)}  #{file} :: #{suite} [#{names}]"
        )

        IO.puts("       #{why}")
      end)

      IO.puts("")
  end
end
