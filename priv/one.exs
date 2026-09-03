# One scenario, measured on its own. The corpus takes minutes; this
# takes seconds, and is what to use while iterating on a batch:
#
#     MIX_ENV=test mix run priv/one.exs timezonestdservice
#
# Prints the passing count and every test that did not pass, with the
# reason the verifier gave.
alias Dav.CalDAVTester.Runner
alias Dav.CalDAVTester.Scenario
alias Dav.CalDAVTester.ServerInfo

file =
  case System.argv() do
    [name | _rest] -> name
    [] -> raise "name a scenario, as in `mix run priv/one.exs timezonestdservice`"
  end

{:ok, substitutions} = ServerInfo.read()

{:ok, scenario} =
  Scenario.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/#{file}.xml")

results = Runner.run(scenario, substitutions)
passed = Enum.count(results, fn {_suite, _test, outcome} -> outcome == :passed end)

IO.puts("#{file}: #{passed}/#{length(results)}")

for {suite, test, outcome} <- results, outcome != :passed do
  IO.puts("  #{suite} :: #{test} #{inspect(outcome, printable_limit: 240)}")
end
