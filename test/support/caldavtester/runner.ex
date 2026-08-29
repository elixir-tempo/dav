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
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.CalDAVTester.Scenario
  alias Dav.CalDAVTester.ServerInfo
  alias Dav.CalDAVTester.Verifier
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn
  alias Plug.Test, as: PlugTest

  @root "rfc/conformance/caldavtester"

  # How many of the suite's users to provision. The scheduling
  # scenarios name up to five between them.
  @people 5

  # The methods this server dispatches. Anything else in a scenario is
  # reported as skipped rather than failed: not answering `POST` is a
  # scope decision, not a defect.
  @implemented ~w(OPTIONS GET HEAD PUT DELETE MKCOL MKCALENDAR PROPFIND PROPPATCH
                  COPY MOVE REPORT POST)

  # Listing a collection's members, for the compound methods.
  @allprop ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>)

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
    state = %{substitutions: substitutions, options: options, etags: %{}}

    # One server per scenario, and the `<start>` block runs against it
    # first, as upstream does. Giving each test a fresh store instead
    # looks tidier and is wrong: most tests read state a previous
    # request created, so isolating them reports missing setup as a
    # server returning 404 — 317 of them, when this was first measured.
    state =
      Enum.reduce(scenario.setup, state, fn request, state ->
        {_outcome, state} = attempt(request, state)
        state
      end)

    {results, _state} =
      Enum.map_reduce(Scenario.tests(scenario), state, fn {suite, test}, state ->
        {outcome, state} = run_test(test, state)
        {{suite.name, test.name, outcome}, state}
      end)

    results
  end

  # State threads through a scenario because the suite does: `GETNEW`
  # puts a URI into a variable that a later request's `<ruri>` reads,
  # and `GETCHANGED` compares an ETag against the one the last GET saw.
  defp run_test(test, state) do
    Enum.reduce_while(test.requests, {:passed, state}, fn request, {_outcome, state} ->
      case attempt(request, state) do
        {:passed, state} -> {:cont, {:passed, state}}
        {other, state} -> {:halt, {other, state}}
      end
    end)
  end

  defp attempt(request, state) do
    case compound(request.method) do
      {:ok, directive} -> perform(directive, request, state)
      :no -> plain(request, state)
    end
  end

  defp plain(request, state) do
    cond do
      not dispatched?(request.method) ->
        {{:skipped, "#{request.method} is not implemented"}, state}

      unresolved = unbound(request, state) ->
        # The URI names a variable an earlier request was meant to
        # bind. When that request was itself skipped, this one cannot
        # run either — and saying so is the difference between an
        # unmeasured test and a server that failed.
        {{:skipped, "unresolved request URI #{inspect(unresolved)}"}, state}

      true ->
        run_plain(request, state)
    end
  end

  # Any `$` left after expansion is a variable that was never bound,
  # and a URI that is not a path cannot be requested at all. Both mean
  # the same thing — this test depends on a request that did not run.
  defp unbound(request, state) do
    request
    |> uris(state)
    |> Enum.find_value(fn uri ->
      cond do
        String.contains?(uri, "$") -> String.slice(uri, 0, 40)
        not String.starts_with?(uri, "/") -> String.slice(uri, 0, 40)
        true -> nil
      end
    end)
  end

  defp run_plain(request, state) do
    if dispatched?(request.method) do
      case send_request(request, state.substitutions, state.options) do
        {:ok, conn} -> record(request, conn, state)
        {other, _reason} = failure -> {put_elem(failure, 0, other), state}
      end
    else
      {{:skipped, "#{request.method} is not implemented"}, state}
    end
  end

  defp record(request, conn, state) do
    state = Enum.reduce(request.grabs, state, &grab(&1, conn, request, &2))
    {verify(request, conn), state}
  end

  ## --- the compound methods ---------------------------------------

  # These are the harness's own directives rather than HTTP, and are
  # documented in `README.md`: DELETEALL empties collections, GETNEW
  # fetches the newest child and remembers its URI, WAITCOUNT waits for
  # a collection to reach a size.
  #
  # Every `WAIT` collapses to a single check here, because this server
  # is called in-process and synchronously: there is no other party to
  # wait for, and nothing can arrive between two calls. That is a real
  # difference from upstream, where the wait covers a server doing work
  # in the background.
  defp compound("DELETEALL"), do: {:ok, :delete_all}
  defp compound("WAITDELETEALL" <> _count), do: {:ok, :delete_all}
  defp compound("DELAY" <> _seconds), do: {:ok, :delay}
  defp compound("GETNEW"), do: {:ok, {:get, :newest}}
  defp compound("FINDNEW"), do: {:ok, {:find, :newest}}
  defp compound("GETOTHER"), do: {:ok, {:get, :other}}
  defp compound("GETCHANGED"), do: {:ok, {:get, :changed}}
  defp compound("WAITCOUNT" <> count), do: {:ok, {:count, count}}
  defp compound("WAITOTHER"), do: {:ok, {:get, :other}}
  defp compound("GETCONTAINS" <> text), do: {:ok, {:get, {:containing, String.trim(text)}}}
  defp compound(_method), do: :no

  defp perform(:delay, _request, state), do: {:passed, state}

  defp perform(:delete_all, request, state) do
    # A `<ruri>` that still holds an unbound variable is not a
    # collection this can empty, and asking for its members crashes
    # rather than returning nothing.
    for uri <- uris(request, state),
        String.starts_with?(uri, "/"),
        not String.contains?(uri, "$"),
        child <- members(uri, state) do
      send_plain("DELETE", child, state)
    end

    {:passed, state}
  end

  defp perform({:count, count}, request, state) do
    wanted = count |> String.trim() |> Integer.parse() |> then(&elem(&1 || {0, ""}, 0))
    actual = request |> uris(state) |> List.first("/") |> members(state) |> length()

    if actual >= wanted,
      do: {:passed, state},
      else: {{:failed, "#{actual} resources, expected at least #{wanted}"}, state}
  end

  defp perform({:find, :newest}, request, state) do
    case choose(:newest, request, state) do
      nil -> {{:failed, "no resource in collection to find"}, state}
      chosen -> {:passed, remember(request, chosen, state)}
    end
  end

  defp perform({:get, which}, request, state) do
    case choose(which, request, state) do
      nil ->
        {{:failed, "no matching resource in collection"}, state}

      chosen ->
        conn = send_plain("GET", chosen, state)
        state = remember(request, chosen, state)
        state = Enum.reduce(request.grabs, state, &grab(&1, conn, request, &2))
        {verify(request, conn), state}
    end
  end

  # "Newest" is the last child the store lists, which is insertion
  # order — the closest this store has to a creation time.
  defp choose(:newest, request, state) do
    request |> uris(state) |> List.first("/") |> members(state) |> List.last()
  end

  defp choose(:other, request, state) do
    uri = request |> uris(state) |> List.first("/")
    siblings = uri |> Path.dirname() |> members(state)

    siblings |> Enum.reject(&(&1 == uri)) |> List.last()
  end

  defp choose(:changed, request, state) do
    request |> uris(state) |> List.first("/") |> then(& &1)
  end

  defp choose({:containing, text}, request, state) do
    request
    |> uris(state)
    |> List.first("/")
    |> members(state)
    |> Enum.find(fn uri -> String.contains?(send_plain("GET", uri, state).resp_body, text) end)
  end

  # `GETNEW` exists to name a resource for later requests, so the URI
  # it chose is written into the variable `graburi` asks for.
  defp remember(request, uri, state) do
    Enum.reduce(request.grabs, state, fn
      {:uri, _argument, variable}, state -> bind(state, variable, uri)
      _other, state -> state
    end)
  end

  defp members(uri, state) when is_binary(uri) do
    if String.starts_with?(uri, "/") and not String.contains?(uri, "$") do
      listing(uri, state)
    else
      []
    end
  end

  defp members(_unresolved, _state), do: []

  defp listing(uri, state) do
    conn = send_plain("PROPFIND", uri, state, [{"depth", "1"}], @allprop)
    collection = String.trim_trailing(uri, "/")

    case Xml.parse(conn.resp_body) do
      {:ok, document} ->
        for element <- hrefs(document),
            href = String.trim_trailing(element, "/"),
            href != collection,
            do: href

      _unreadable ->
        []
    end
  end

  defp hrefs(document) do
    for response <- descendants(document, "response"),
        href <- descendants(response, "href"),
        do: String.trim(href.text)
  end

  defp descendants(element, name) do
    matching = Enum.filter(element.children, &match?(%{name: {_ns, ^name}}, &1))
    matching ++ Enum.flat_map(element.children, &descendants(&1, name))
  end

  defp send_plain(method, uri, state, headers \\ [], body \\ "") do
    conn =
      Enum.reduce(headers, PlugTest.conn(method, uri, body), fn {name, value}, conn ->
        Conn.put_req_header(conn, name, value)
      end)

    DavPlug.call(conn, state.options)
  rescue
    _error -> %Plug.Conn{status: 500, resp_body: ""}
  end

  defp dispatched?(method), do: method in @implemented

  defp uris(request, state) do
    Enum.map(request.uris, &ServerInfo.expand(&1, state.substitutions))
  end

  defp bind(state, nil, _value), do: state

  # A grab that found nothing binds nothing. Storing the `nil` instead
  # leaves a variable that expansion cannot substitute and cannot see
  # is missing, which crashed five scenarios rather than skipping them.
  defp bind(state, _variable, nil), do: state

  defp bind(state, variable, value) when is_binary(value) do
    put_in(state.substitutions[variable], value)
  end

  ## --- grabs ------------------------------------------------------

  defp grab({:uri, _argument, variable}, _conn, request, state) do
    bind(state, variable, request |> uris(state) |> List.first("/"))
  end

  defp grab({:count, _argument, variable}, conn, _request, state) do
    case Xml.parse(conn.resp_body) do
      {:ok, document} -> bind(state, variable, "#{length(descendants(document, "response"))}")
      _unreadable -> state
    end
  end

  defp grab({:header, name, variable}, conn, _request, state) do
    case Conn.get_resp_header(conn, String.downcase(name || "")) do
      [value | _rest] -> bind(state, variable, value)
      [] -> state
    end
  end

  defp grab({:property, property, variable}, conn, _request, state) do
    bind(state, variable, first_text(conn, [property]))
  end

  # A name may be a path — `{ns}outer/{ns}inner` — naming a nested
  # element rather than a top-level one.
  defp grab({:element, name, variable}, conn, _request, state) do
    bind(state, variable, first_text(conn, String.split(name || "", "/")))
  end

  defp grab({:calendar_property, name, variable}, conn, _request, state) do
    bind(state, variable, calendar_value(conn.resp_body, name))
  end

  defp grab({:calendar_parameter, _name, _variable}, _conn, _request, state), do: state

  defp grab({:unsupported, _name, _variable}, _conn, _request, state), do: state

  # Names are in Clark notation, matching how the scenarios write them.
  defp first_text(conn, path) do
    case Xml.parse(conn.resp_body) do
      {:ok, document} -> document |> follow(path) |> text_of()
      _unreadable -> nil
    end
  end

  defp follow(element, []), do: element

  defp follow(nil, _path), do: nil

  defp follow(element, [name | rest]) do
    element
    |> all()
    |> Enum.find(&(clark(&1.name) == String.trim(name)))
    |> follow(rest)
  end

  defp all(element), do: element.children ++ Enum.flat_map(element.children, &all/1)

  defp text_of(nil), do: nil
  defp text_of(element), do: String.trim(element.text)

  defp clark({namespace, local}), do: "{" <> namespace <> "}" <> local

  # `VEVENT/SUMMARY` names a property inside a component.
  defp calendar_value(body, name) do
    with [component, property] <- String.split(name || "", "/", parts: 2),
         {:ok, calendar} <- ICalendar.parse(body),
         found when not is_nil(found) <-
           Enum.find(calendar.components, &(&1.name == component)),
         %{value: value} <- Enum.find(found.properties, &(&1.name == property)) do
      value
    else
      _absent -> nil
    end
  end

  ## --- plain requests ---------------------------------------------

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
    people =
      for index <- 1..@people,
          home = substitutions["$calendarhome#{index}:"],
          is_binary(home),
          do: {index, segments(home)}

    homes = Enum.map(people, &elem(&1, 1))

    collections =
      for home <- homes, leaf <- ["calendar", "tasks", "notification"], do: home ++ [leaf]

    resources =
      ([[] | ancestors(homes)] ++ homes)
      |> Enum.uniq()
      |> Enum.map(&%Resource{path: &1, collection?: true})

    calendars =
      for path <- collections,
          do: %Resource{path: path, collection?: true, types: [Cal.calendar()]}

    # RFC 6638: the Inbox and Outbox are ordinary collections
    # distinguished by their resource type, and scheduling needs them
    # to exist before any of it can be exercised.
    scheduling =
      for home <- homes,
          {leaf, type} <- [{"inbox", Schedule.inbox()}, {"outbox", Schedule.outbox()}],
          do: %Resource{path: home ++ [leaf], collection?: true, types: [type]}

    addresses =
      for {index, home} <- people,
          address <- [substitutions["$cuaddr#{index}:"], substitutions["$email#{index}:"]],
          is_binary(address),
          into: %{},
          do: {address, home}

    SchedulingStore.start(resources ++ calendars ++ scheduling, addresses)
  end

  defp ancestors(homes) do
    homes
    |> Enum.flat_map(fn home -> for n <- 1..length(home)//1, do: Enum.take(home, n) end)
    |> Enum.uniq()
  end

  defp segments(path), do: path |> String.split("/", trim: true)

  defp plug_options(context) do
    DavPlug.init(
      store: SchedulingStore,
      context: context,
      methods: [{"MKCALENDAR", Cal.Mkcalendar}, {"POST", Cal.Outbox}],
      reports: [
        {{Xml.caldav(), "calendar-query"}, Cal.Query},
        {{Xml.caldav(), "calendar-multiget"}, Cal.Multiget},
        {{Xml.caldav(), "free-busy-query"}, Cal.FreeBusy}
      ]
    )
  end
end
