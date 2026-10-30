# The conformance deployment over real HTTP, for Apple's own harness
# to drive. The in-process runner (`priv/one.exs`, `mix test`) measures
# the protocol; this measures the deployment — Bandit, the wire, and
# the authentication the scenarios assume.
#
#     MIX_ENV=test mix run --no-halt priv/serve.exs [port]
#
# Then point CalDAVTester at it with a `serverinfo.xml` whose host and
# port match. See rfc/conformance/caldavtester/FETCHING.md.
#
# Starting the server also restates the built harness's own copy of
# `serverinfo.xml` for this deployment — see `ServerInfo.deployed/1`.
# Rebuilding the harness with `priv/caldavtester.py` puts Apple's back,
# so restart the server after a rebuild.
alias Dav.CalDAVTester.Endpoint
alias Dav.CalDAVTester.ServerInfo

port =
  case System.argv() do
    [given | _rest] -> String.to_integer(given)
    [] -> 8008
  end

{:ok, substitutions} = ServerInfo.read()
options = Endpoint.provisioned(substitutions)

# CalDAVTester reads its own copy of `serverinfo.xml`, and Apple's
# describes CalendarServer — every feature it has, tasks kept apart
# from events. Written here, as the listener comes up, so the harness
# is only ever pointed at a description of the server that answers.
harness = "_build/caldavtester/caldavtester/scripts/server/serverinfo.xml"

restated =
  if File.dir?(Path.dirname(harness)) do
    {:ok, document} = ServerInfo.deployed()
    File.write!(harness, document)
    "restated for this deployment"
  else
    "not built — run priv/caldavtester.py first"
  end

{:ok, _server} =
  Bandit.start_link(plug: {Endpoint, options}, scheme: :http, port: port, ip: {127, 0, 0, 1})

IO.puts("""
CalDAV conformance deployment on http://localhost:#{port}
  accounts: #{map_size(options.principals)} (password is the account name)
  harness serverinfo.xml: #{restated}
  stop with ctrl-c
""")

# Bandit is linked to this process, and its supervisor traps exits — so
# letting the script finish takes the listener down with it, leaving a
# beam that is running and a port that is closed.
Process.sleep(:infinity)
