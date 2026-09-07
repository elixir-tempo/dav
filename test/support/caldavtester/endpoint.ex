defmodule Dav.CalDAVTester.Endpoint do
  @moduledoc """
  The conformance deployment, served over real HTTP.

  `Dav.CalDAVTester.Runner` drives the scenarios in-process, which is
  what makes the corpus cheap enough to run on every build — and its
  own moduledoc says what that costs: nothing there exercises Bandit,
  TLS, authentication or concurrency. It measures the protocol, not
  the deployment.

  This is the other half. The same store, the same plug options, the
  same provisioning and the same routing, behind a socket, so Apple's
  own harness can drive it the way a client would. Two things come of
  that:

  * the parts the in-process runner cannot reach are exercised — the
    server, the wire, and the authentication the scenarios assume; and

  * the in-process port is checked against the original. Where the two
    disagree about a scenario, the port is wrong, and neither of them
    alone can tell you that.

  ## Authentication

  The scenarios authenticate as `user01`, `user02`, `admin` and the
  rest, and every account's password is its own name — the reference
  deployment's convention, which `scripts/server/serverinfo.xml`
  states and this reads rather than restates.

  `Dav.Web.Plug` takes the principal as an option and answers `401`
  when a request that needs one has none. Deciding *who* is asking is
  the deployment's, which is why it happens here: a library that
  parsed credentials would be choosing a scheme for everybody.

  Deciding *whether* anyone need be asking is the plug's, which is why
  it does not happen here. Some requests are answerable by a stranger:
  RFC 6764's `/.well-known/caldav` is how a client holding nothing but
  a hostname finds the service, and a server-to-server receiver takes
  messages from senders who hold no account at all. The plug knows
  both; a deployment that challenged first would refuse the one
  request discovery exists for.

  ## Running it

      MIX_ENV=test mix run --no-halt priv/serve.exs

  """

  @behaviour Plug

  import Plug.Conn

  alias Dav.CalDAVTester.Runner

  @doc """
  Provision the deployment and describe how to serve it.

  ### Arguments

  * `substitutions` is the environment from
    `Dav.CalDAVTester.ServerInfo.read/1`.

  ### Returns

  * The options `call/2` takes: the plug options for the provisioned
    store, and the principal each account authenticates to.

  """
  @spec provisioned(map()) :: map()
  def provisioned(substitutions) do
    context = Runner.provision(nil, substitutions)

    %{options: Runner.plug_options(context, substitutions), principals: principals(substitutions)}
  end

  @doc """
  Nothing to configure beyond what `provisioned/1` returns.

  ### Arguments

  * `options` are the options, passed through.

  ### Returns

  * The options, unchanged.

  """
  @impl Plug
  @spec init(map()) :: map()
  def init(options), do: options

  @doc """
  Serve one request as whoever authenticated.

  ### Arguments

  * `conn` is the request.

  * `options` is what `provisioned/1` returned.

  ### Returns

  * The connection, answered — or challenged by the plug, when the
    request needs a principal and the credentials are missing or name
    nobody.

  """
  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, %{options: options, principals: principals}) do
    Runner.route(conn, %{options | principal: named(conn, principals)})
  end

  defp named(conn, principals) do
    with ["Basic " <> encoded | _rest] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [account, password] <- String.split(decoded, ":", parts: 2),
         true <- password == account do
      Map.get(principals, account)
    else
      _unauthenticated -> nil
    end
  end

  # Every account the scenarios name, mapped to the principal it acts
  # as. The numbered accounts come in a block; the named ones —
  # `admin`, `apprentice`, `proxy` — are spelled out in the same file
  # and have to be picked up by name.
  defp principals(substitutions) do
    numbered =
      for {"$userid" <> index, account} <- substitutions,
          String.ends_with?(index, ":"),
          uri = substitutions["$principaluri#{String.trim_trailing(index, ":")}:"],
          is_binary(uri),
          into: %{},
          do: {account, uri}

    named =
      for role <- ~w(admin apprentice proxy),
          account = substitutions["$user#{role}:"],
          uri = substitutions["$principaluri_#{role}:"],
          is_binary(account) and is_binary(uri),
          into: %{},
          do: {account, uri}

    Map.merge(numbered, named)
  end
end
