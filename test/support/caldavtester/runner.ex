defmodule Dav.CalDAVTester.Runner do
  @moduledoc """
  Runs CalDAVTester scenarios against `Dav.Web.Plug`, in Elixir.

  Upstream's harness is Python: it drives a live server over HTTP with
  provisioned accounts and authentication. This runs the same scenario
  files in-process through `Plug.Test`, which needs no Python, no
  socket and no account database, and so can run in CI beside the rest
  of the suite.

  What that costs is real and worth stating: nothing here exercises
  Bandit, TLS, authentication or concurrency. It measures the
  protocol, not the deployment.

  ### An unimplemented check is a skip, never a pass

  A scenario reaching a verifier this module does not implement, a
  method the server does not dispatch, or a `grab` — which feeds a
  value from one response into a later request — is reported as
  **skipped, with the reason**. The failure mode to avoid is a harness
  that quietly counts what it did not check, which turns a coverage
  measurement into a fiction.

  """

  alias Dav.Cal
  alias Dav.CalDAVTester.Scenario
  alias Dav.CalDAVTester.ServerInfo
  alias Dav.CalDAVTester.Verifier
  alias Dav.Test.WritableStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn
  alias Plug.Test, as: PlugTest

  @root "rfc/conformance/caldavtester"

  @typedoc "What became of one test."
  @type outcome :: :passed | {:failed, String.t()} | {:skipped, String.t()}

  @doc """
  Run every test in a scenario.

  ### Arguments

  * `scenario` is a `t:Dav.CalDAVTester.Scenario.t/0`.

  * `substitutions` is the environment from
    `Dav.CalDAVTester.ServerInfo.read/1`.

  ### Returns

  * A list of `{suite_name, test_name, outcome}`, in scenario order.

  """
  @spec run(Scenario.t(), map()) :: [{String.t(), String.t(), outcome()}]
  def run(scenario, substitutions) do
    options = scenario |> provision(substitutions) |> plug_options()

    # One server per scenario, and the `<start>` block runs against it
    # first, as upstream does. Giving each test a fresh store instead
    # looks tidier and is wrong: most tests read state a previous
    # request created, so isolating them reports missing setup as a
    # server returning 404 — 317 of them, when this was first measured.
    setup(scenario, substitutions, options)

    for {suite, test} <- Scenario.tests(scenario) do
      {suite.name, test.name, run_test(test, substitutions, options)}
    end
  end

  defp setup(scenario, substitutions, options) do
    for request <- scenario.setup, do: attempt(request, substitutions, options)
    :ok
  end

  defp run_test(test, substitutions, options) do
    Enum.reduce_while(test.requests, :passed, fn request, _outcome ->
      case attempt(request, substitutions, options) do
        :passed -> {:cont, :passed}
        other -> {:halt, other}
      end
    end)
  end

  defp attempt(request, substitutions, options) do
    with :ok <- supported(request, options),
         {:ok, conn} <- send_request(request, substitutions, options) do
      verify(request, conn)
    end
  end

  defp supported(request, options) do
    cond do
      request.grabs != [] ->
        {:skipped, "needs #{Enum.join(request.grabs, ", ")} — values carried between requests"}

      not dispatched?(request.method, options) ->
        {:skipped, "#{request.method} is not implemented"}

      true ->
        :ok
    end
  end

  # The pseudo-methods are the harness's own directives rather than
  # HTTP: DELETEALL empties a collection, WAITCOUNT polls until a count
  # is reached. They belong to the runner, not the server.
  @pseudo ~w(DELETEALL DELAY GETNEW WAITCOUNT WAITDELETEALL GETCHANGED GETOTHER
             GETCONTAINS FINDNEW WAITOTHER)

  @implemented ~w(OPTIONS GET HEAD PUT DELETE MKCOL MKCALENDAR PROPFIND PROPPATCH
                  COPY MOVE REPORT)

  defp dispatched?(method, _options), do: method in @implemented and method not in @pseudo

  defp send_request(request, substitutions, options) do
    uri = request.uris |> List.first("/") |> ServerInfo.expand(substitutions)
    body = body(request, substitutions)

    conn =
      PlugTest.conn(request.method, uri, body)
      |> put_headers(request.headers, substitutions)
      |> put_content_type(request.data)

    {:ok, DavPlug.call(conn, options)}
  rescue
    error -> {:failed, "request raised #{inspect(error.__struct__)}: #{Exception.message(error)}"}
  catch
    kind, reason -> {:failed, "request #{kind}: #{inspect(reason)}"}
  end

  defp body(%{data: nil}, _substitutions), do: ""

  defp body(%{data: %{filepath: nil}}, _substitutions), do: ""

  defp body(%{data: %{filepath: filepath}}, substitutions) do
    case File.read(Path.join(@root, filepath)) do
      {:ok, contents} -> ServerInfo.expand(contents, substitutions)
      _missing -> ""
    end
  end

  defp put_headers(conn, headers, substitutions) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Conn.put_req_header(
        conn,
        String.downcase(name),
        ServerInfo.expand(value || "", substitutions)
      )
    end)
  end

  defp put_content_type(conn, nil), do: conn

  defp put_content_type(conn, %{content_type: nil}), do: conn

  defp put_content_type(conn, %{content_type: type}),
    do: Conn.put_req_header(conn, "content-type", type)

  defp verify(request, conn) do
    Enum.reduce_while(request.verifiers, :passed, fn check, _outcome ->
      case Verifier.run(check, conn) do
        :passed -> {:cont, :passed}
        other -> {:halt, other}
      end
    end)
  end

  ## --- the server under test --------------------------------------

  @doc """
  Provision a store matching the substitution environment.

  The scenarios address a calendar home at `$calendarhome1:` holding a
  `calendar` collection, so those must exist before a request can do
  anything. Built for the first two users, which is as many as the
  non-scheduling scenarios name.

  ### Arguments

  * `substitutions` is the environment from
    `Dav.CalDAVTester.ServerInfo.read/1`.

  ### Returns

  * The store's context, an `Agent`.

  """
  @spec provision(Scenario.t(), map()) :: pid()
  def provision(_scenario, substitutions) do
    homes =
      for index <- 1..2,
          home = substitutions["$calendarhome#{index}:"],
          is_binary(home),
          do: segments(home)

    collections =
      for home <- homes, leaf <- ["calendar", "inbox", "outbox", "tasks"], do: home ++ [leaf]

    resources =
      ([[] | ancestors(homes)] ++ homes)
      |> Enum.uniq()
      |> Enum.map(&%Resource{path: &1, collection?: true})

    calendars =
      for path <- collections,
          do: %Resource{path: path, collection?: true, types: [Cal.calendar()]}

    WritableStore.start(resources ++ calendars)
  end

  defp ancestors(homes) do
    homes
    |> Enum.flat_map(fn home -> for n <- 1..length(home)//1, do: Enum.take(home, n) end)
    |> Enum.uniq()
  end

  defp segments(path), do: path |> String.split("/", trim: true)

  defp plug_options(context) do
    DavPlug.init(
      store: WritableStore,
      context: context,
      methods: [{"MKCALENDAR", Cal.Mkcalendar}],
      reports: [
        {{Xml.caldav(), "calendar-query"}, Cal.Query},
        {{Xml.caldav(), "calendar-multiget"}, Cal.Multiget},
        {{Xml.caldav(), "free-busy-query"}, Cal.FreeBusy}
      ]
    )
  end
end
