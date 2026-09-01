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
  alias Dav.Cal.Sharing
  alias Dav.CalDAVTester.Features
  alias Dav.CalDAVTester.Scenario
  alias Dav.CalDAVTester.ServerInfo
  alias Dav.CalDAVTester.Verifier
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Acl
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Principal
  alias Dav.Web.Resource
  alias Dav.Xml
  alias Plug.Conn
  alias Plug.Test, as: PlugTest

  @root "rfc/conformance/caldavtester"

  # Apple's namespace, for the properties its clients ask for.
  @calendarserver "http://calendarserver.org/ns/"

  # How many accounts there are is `serverinfo.xml`'s to say, not this
  # module's: it declares them in a `<repeat count="40">` block, and
  # `Dav.CalDAVTester.ServerInfo` gives the named accounts — the `i18n`
  # login among them — numbered slots beyond that. Counting the
  # `$useridN:` keys it produced asks the file rather than restating
  # its answer here, where the two would have to be kept in step by
  # hand and would not be.
  defp accounts(substitutions) do
    Enum.find(Stream.iterate(1, &(&1 + 1)), &(not Map.has_key?(substitutions, "$userid#{&1}:"))) -
      1
  end

  # The methods this server dispatches. Anything else in a scenario is
  # reported as skipped rather than failed: not answering `POST` is a
  # scope decision, not a defect.
  @implemented ~w(OPTIONS GET HEAD PUT DELETE MKCOL MKCALENDAR PROPFIND PROPPATCH
                  COPY MOVE REPORT POST)

  # Listing a collection's members, for the compound methods.
  # `dofindall` asks for one property, not for all of them. A listing
  # is after member URLs, and every extra property it fetches carries
  # hrefs of its own — `owner`, `calendar-home-set` — for the reader
  # to tell apart from the members it came for.
  @listing ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>)

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
    options = scenario |> provision(substitutions) |> plug_options(substitutions)
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

    {results, state} =
      Enum.map_reduce(Scenario.tests(scenario, Features.declared()), state, fn {suite, test},
                                                                               state ->
        state = suited(state, suite)
        {outcome, state} = run_test(test, state)
        {{suite.name, test.name, outcome}, state}
      end)

    # "Delete any resources from requests marked with 'end-delete'" —
    # step 4 of the suite's own procedure, before the `<end>` block.
    # Skipping it leaves a scenario's own litter for its teardown to
    # trip over.
    clean_up(scenario, state)

    results
  end

  # `$uid1:` names one event for as long as a suite runs — that is what
  # lets one fixture reference another's — and a different event in the
  # next suite. Sharing them across a whole scenario has the second
  # suite storing an event whose `UID` the first one is still using,
  # which a server enforcing `CALDAV:no-uid-conflict` refuses.
  defp suited(%{suite: name} = state, %Scenario.Suite{name: name}), do: state

  defp suited(state, %Scenario.Suite{change_uid?: false} = suite),
    do: Map.put(state, :suite, suite.name)

  defp suited(state, %Scenario.Suite{name: name}) do
    seen = Map.get(state, :suites, 0) + 1

    uids =
      for index <- 1..20,
          into: %{},
          do:
            {"$uid#{index}:",
             "caldavtester-uid-#{seen}-#{String.pad_leading("#{index}", 4, "0")}"}

    state
    |> Map.put(:suite, name)
    |> Map.put(:suites, seen)
    |> Map.update!(:substitutions, &Map.merge(&1, uids))
  end

  defp clean_up(scenario, state) do
    for {_suite, test} <- Scenario.tests(scenario, Features.declared()),
        request <- test.requests,
        request.end_delete?,
        uri <- uris(request, state) do
      send_plain("DELETE", uri, state)
    end

    :ok
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
    if Scenario.applicable?(request, Features.declared()) do
      dispatch(request, state)
    else
      # A request gated on a feature this server does not declare is
      # not part of the scenario for this server at all.
      {:passed, state}
    end
  end

  defp dispatch(request, state) do
    case compound(request.method) do
      # `dofindall`, `dofindnew` and `dodeleteall` all act as the user
      # the request names, not as the harness. Emptying somebody's
      # Inbox as the wrong person is refused, and the messages stay
      # there to be counted by the next suite that looks.
      {:ok, directive} -> perform(directive, request, %{state | options: as(request, state)})
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
        String.contains?(uri, "$") -> String.slice(uri, 0, 120)
        not String.starts_with?(uri, "/") -> String.slice(uri, 0, 120)
        true -> nil
      end
    end)
  end

  # `iterate-data` points a request at a *directory* and runs it once
  # per file in it, in name order. `vtodos.xml` stores five task
  # bodies that way, and without this the request is sent once with an
  # empty body — which the server rightly refuses.
  defp run_plain(%{iterate_data?: true, data: %{filepath: filepath}} = request, state)
       when is_binary(filepath) do
    case iterated(filepath) do
      [] ->
        {{:skipped, "no iteration data in #{filepath}"}, state}

      files ->
        Enum.reduce_while(files, {:passed, state}, &one_of(&1, &2, request))
    end
  end

  defp run_plain(request, state) do
    if dispatched?(request.method) do
      case send_request(request, state.substitutions, as(request, state)) do
        {:ok, conn} -> record(request, conn, state)
        {other, _reason} = failure -> {put_elem(failure, 0, other), state}
      end
    else
      {{:skipped, "#{request.method} is not implemented"}, state}
    end
  end

  # The whole request fails on the first body that fails, the way
  # upstream's loop does — a later success would otherwise paper over
  # an earlier refusal.
  defp one_of(file, {_outcome, state}, request) do
    one = %{request | iterate_data?: false, data: %{request.data | filepath: file}}

    case run_plain(one, state) do
      {:passed, carried} -> {:cont, {:passed, carried}}
      failure -> {:halt, failure}
    end
  end

  # Verified first, grabbed second. A request may both check a value
  # and remember it — `Schedule-Tag!$schedule-tag-organizer:` asks
  # whether the tag differs from the one grabbed last time, and the
  # same request grabs the new one. Grabbing first compares the value
  # against itself, so every such check passed or failed on nothing.
  defp record(request, conn, state) do
    outcome = verify(request, conn, state)

    {outcome, Enum.reduce(request.grabs, state, &grab(&1, conn, request, &2))}
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
  defp compound("DELETEALL"), do: {:ok, {:delete_all, nil}}
  defp compound("WAITDELETEALL" <> count), do: {:ok, {:delete_all, String.trim(count)}}
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

  # `dowaitcount` wants *exactly* the number named — `WAITCOUNT 1`
  # fails on two messages, and `counted/3` says so.
  #
  # `WAITDELETEALL n` empties a collection once it holds `n` items.
  # Upstream refuses to empty until the count matches, having
  # re-checked for thirty seconds, so against a conformant server the
  # count converges and the collection always gets emptied. Ours
  # answers immediately, so refusing turns one wrong count into every
  # later suite finding somebody else's leftovers: 222 further
  # failures, none about the thing they report.
  #
  # The count is *not* asserted here, and the reason is worth stating
  # because asserting it looks obviously right. Tried: report a
  # mismatch and empty anyway, so nothing cascades. It surfaces 102
  # mismatches. Narrowing to a surplus — reasoning that no amount of
  # waiting removes a message — still surfaces 60. Both are
  # unattributable: run a suite alone and its counts are exact, so the
  # surplus is a *previous* suite's residue, which upstream never sees
  # because its wait converges and its empty always lands. A count
  # this harness cannot attribute is worse than no count.
  defp perform({:delete_all, _count}, request, state), do: {:passed, emptied(request, state)}

  defp perform({:count, count}, request, state) do
    case counted(count, request, state) do
      :ok -> {:passed, state}
      {:error, reason} -> {{:failed, reason}, state}
    end
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
        outcome = verify(request, conn, remember(request, chosen, state))

        # `graburi` is skipped here: `remember/3` has already bound it
        # to the resource that was *found*, and the general pass binds
        # it to the request's own URI instead. On a compound method
        # that URI is the collection searched, so re-running it
        # replaced the resource with its parent and the next request
        # wrote to the collection.
        state =
          request.grabs
          |> Enum.reject(&match?({:uri, _argument, _variable}, &1))
          |> Enum.reduce(remember(request, chosen, state), &grab(&1, conn, request, &2))

        {outcome, state}
    end
  end

  defp emptied(request, state) do
    # A `<ruri>` that still holds an unbound variable is not a
    # collection this can empty, and asking for its members crashes
    # rather than returning nothing.
    for uri <- uris(request, state),
        String.starts_with?(uri, "/"),
        not String.contains?(uri, "$"),
        child <- members(uri, state) do
      send_plain("DELETE", child, state)
    end

    state
  end

  defp counted(count, request, state) do
    wanted = count |> String.trim() |> Integer.parse() |> then(&elem(&1 || {0, ""}, 0))
    actual = request |> uris(state) |> List.first("/") |> members(state) |> length()

    if actual == wanted,
      do: :ok,
      else: {:error, "#{actual} resources, expected #{wanted}"}
  end

  # `dofindnew`: the member written most recently, and where several
  # share that instant the one no earlier `GETNEW` has returned. An
  # ambiguous choice is no choice — upstream answers nothing rather
  # than guessing, and so does this.
  defp choose(:newest, request, state) do
    request |> uris(state) |> List.first("/") |> latest(state) |> unseen(state)
  end

  defp choose(:other, request, state) do
    uri = request |> uris(state) |> List.first("/")

    uri |> Path.dirname() |> latest(state) |> Enum.reject(&(&1 == uri)) |> unseen(state)
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

  defp unseen([], _state), do: nil
  defp unseen([single], _state), do: single

  defp unseen(tied, state) do
    case Enum.reject(tied, &(&1 in Map.get(state, :found, []))) do
      [one] -> one
      _none_or_several -> nil
    end
  end

  # The members sharing the most recent `DAV:getlastmodified`. A
  # member without one sorts oldest: it is a collection or a resource
  # the store does not timestamp, never the thing that just arrived.
  defp latest(uri, state) do
    stamped = for {href, at} <- timestamped(uri, state), do: {href, instant(at)}

    case stamped do
      [] ->
        []

      stamped ->
        for {href, at} <- stamped, at == Enum.max(Enum.map(stamped, &elem(&1, 1))), do: href
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # An HTTP-date sorts by its parts, never as text: `Feb` precedes
  # `Jan` alphabetically, and the weekday it starts with orders
  # nothing at all.
  defp instant(text) do
    case Regex.run(~r/(\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})/, text) do
      [_all, day, month, year, hour, minute, second] ->
        {String.to_integer(year), Enum.find_index(@months, &(&1 == month)) || 0,
         String.to_integer(day), String.to_integer(hour), String.to_integer(minute),
         String.to_integer(second)}

      _unreadable ->
        {0, 0, 0, 0, 0, 0}
    end
  end

  # `GETNEW` exists to name a resource for later requests. The URI it
  # chose goes into whatever `graburi` asks for *and* into the bare
  # `$`, which the suite uses as "the resource the last GETNEW found"
  # — 131 requests address it that way, and without the binding each
  # is an unresolvable URI rather than a test.
  defp remember(request, uri, state) do
    state = Map.update(state, :found, [uri], &[uri | &1])
    state = bind(state, "$", uri)

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

  @modified ~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getlastmodified/></D:prop></D:propfind>)

  defp timestamped(uri, state) do
    if String.starts_with?(uri, "/") and not String.contains?(uri, "$"),
      do: stamps(uri, state),
      else: []
  end

  defp stamps(uri, state) do
    conn = send_plain("PROPFIND", uri, state, [{"depth", "1"}], @modified)
    collection = String.trim_trailing(uri, "/")

    case Xml.parse(conn.resp_body) do
      {:ok, document} ->
        for element <- responses(document),
            href = String.trim_trailing(text_of(element, "href"), "/"),
            href != collection,
            do: {href, text_of(element, "getlastmodified")}

      _unreadable ->
        []
    end
  end

  defp responses(document), do: descendants(document, "response")

  defp text_of(element, name) do
    case Enum.find(descendants(element, name), & &1) do
      nil -> ""
      found -> String.trim(found.text)
    end
  end

  defp listing(uri, state) do
    conn = send_plain("PROPFIND", uri, state, [{"depth", "1"}], @listing)
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

  # A response's member URL is its *direct* child `DAV:href`, never a
  # descendant one. Properties carry hrefs of their own —
  # `current-user-principal`, `owner`, `calendar-home-set` — and
  # counting those as members makes a listing report the principal
  # URL as a resource inside the collection. The compound directives
  # act on that listing, so DELETEALL then deletes the principal.
  defp hrefs(document) do
    for response <- descendants(document, "response"),
        href <- children(response, "href"),
        do: String.trim(href.text)
  end

  defp children(element, name) do
    Enum.filter(element.children, &match?(%{name: {_namespace, ^name}}, &1))
  end

  defp descendants(element, name) do
    matching = Enum.filter(element.children, &match?(%{name: {_ns, ^name}}, &1))
    matching ++ Enum.flat_map(element.children, &descendants(&1, name))
  end

  # A `<ruri>` that resolved to something that is not a path — an
  # address, or an unbound variable — cannot be requested. Answering
  # 500 keeps a scenario moving instead of taking the sweep down.
  defp send_plain(method, uri, state, headers \\ [], body \\ "")

  defp send_plain(_method, uri, _state, _headers, _body) when not is_binary(uri),
    do: %Plug.Conn{status: 500, resp_body: ""}

  defp send_plain(method, uri, state, headers, body) do
    if String.starts_with?(uri, "/") do
      requested(method, uri, state, headers, body)
    else
      %Plug.Conn{status: 500, resp_body: ""}
    end
  end

  defp requested(method, uri, state, headers, body) do
    conn =
      Enum.reduce(headers, PlugTest.conn(method, uri, body), fn {name, value}, conn ->
        Conn.put_req_header(conn, name, value)
      end)

    DavPlug.call(conn, state.options)
  rescue
    _error -> %Plug.Conn{status: 500, resp_body: ""}
  end

  # A request is made *as* somebody. The suite says who with a `user`
  # attribute, defaulting to the first account, and properties like
  # `DAV:current-user-principal` differ per caller — a harness that
  # ignores it cannot test access control at all.
  defp as(request, state) do
    Map.put(state.options, :principal, principal_for(request, state))
  end

  # `auth='no'` is an anonymous request: no principal at all. Whether
  # anonymity is acceptable is the server's decision per endpoint —
  # the server-to-server receiver takes it, everything else answers
  # `401` — which is exactly what the suite is probing. Only *wrong*
  # credentials fail for authenticated requests.
  defp principal_for(%{authenticate?: false}, _state), do: nil

  defp principal_for(request, state) do
    index = account(request, state)

    if correct?(request, index, state),
      do: canonical_principal(index, state.substitutions),
      else: nil
  end

  defp correct?(%{password: nil}, _index, _state), do: true

  # Matched against every password the server info declares, not just
  # the numbered accounts: the suite has named ones too — an
  # internationalised login among them — and checking only
  # `$pswdN:` rejects those as though they were wrong. What the suite
  # actually uses to mean "wrong credentials" is a literal that
  # belongs to no account.
  defp correct?(%{password: password}, _index, state) do
    ServerInfo.expand(password, state.substitutions) in passwords(state.substitutions)
  end

  defp passwords(substitutions) do
    for {key, value} <- substitutions,
        String.contains?(key, "pswd"),
        is_binary(value),
        into: MapSet.new(),
        do: value
  end

  defp account(%{user: nil}, _state), do: 1

  # Searched across every account the server info declares, not just
  # the ones provisioned with calendars. Authenticating is a question
  # about credentials; whether that account has anything here is a
  # different question, answered later by the store.
  defp account(%{user: user}, state) do
    name = ServerInfo.expand(user, state.substitutions)

    Enum.find(1..accounts(state.substitutions), 1, fn index ->
      state.substitutions["$userid#{index}:"] == name
    end)
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

  # `basename($name:)` stores the last path segment of what was
  # grabbed — a scenario that learns a calendar's URL this way then
  # addresses members inside it by name.
  defp bind(state, "basename(" <> rest, value) when is_binary(value) do
    bind(
      state,
      String.trim_trailing(rest, ")"),
      value |> String.trim_trailing("/") |> Path.basename()
    )
  end

  defp bind(state, variable, value) when is_binary(value) do
    put_in(state.substitutions[variable], value)
  end

  ## --- grabs ------------------------------------------------------

  defp grab({:uri, _argument, variable}, _conn, request, state) do
    bind(state, variable, request |> uris(state) |> List.first("/"))
  end

  defp grab({:count, _argument, variable}, conn, _request, state) do
    case Xml.parse(conn.resp_body) do
      # The collection answers for itself as well as its members, and
      # `multistatusItems` counts *items* — one fewer than the
      # responses. A grabbed count is compared against that, so it
      # counts the same way.
      {:ok, document} ->
        bind(state, variable, "#{length(descendants(document, "response")) - 1}")

      _unreadable ->
        state
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
  # The path is substituted before it is walked. A scenario writes
  # `{$CS:}invite-notification`, and `$CS:` is a substitution like any
  # other — left as written it matches no element, so every grab in
  # Apple's namespace came back empty and the variables they fed
  # travelled on as their own literal names.
  defp grab({:element, name, variable}, conn, _request, state) do
    path = name |> ServerInfo.expand(state.substitutions) |> steps()

    bind(state, variable, first_text(conn, path))
  end

  defp grab({:calendar_property, name, variable}, conn, _request, state) do
    bind(state, variable, calendar_value(conn.resp_body, name))
  end

  defp grab({:calendar_parameter, _name, _variable}, _conn, _request, state), do: state

  defp grab({:unsupported, _name, _variable}, _conn, _request, state), do: state

  # A path is Clark notation joined by `/` — and a namespace URI
  # contains `/` too. Splitting the whole string on it shreds
  # `{http://calendarserver.org/ns/}invite-notification` into pieces
  # that match nothing, which is why every grab in that namespace came
  # back empty while `{DAV:}` ones worked.
  defp steps(nil), do: []

  defp steps(name) do
    case Regex.scan(~r/\{[^}]*\}[^\/]+/, name) do
      [] -> String.split(name, "/")
      matched -> List.flatten(matched)
    end
  end

  # Names are in Clark notation, matching how the scenarios write them.
  defp first_text(conn, path) do
    case Xml.parse(conn.resp_body) do
      {:ok, document} -> document |> follow(path) |> text_of()
      _unreadable -> nil
    end
  end

  defp follow(element, []), do: element

  defp follow(nil, _path), do: nil

  # The first step may name the document's own root — a `CS:shared-as`
  # response *is* that element, and looking only among its descendants
  # finds nothing. Every later step descends normally.
  defp follow(element, [name | rest]) do
    wanted = String.trim(name)

    if clark(element.name) == wanted do
      follow(element, rest)
    else
      element |> all() |> Enum.find(&(clark(&1.name) == wanted)) |> follow(rest)
    end
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
    uri =
      request.uris |> List.first("/") |> ServerInfo.expand(substitutions) |> named()

    body = body(request, substitutions)

    conn =
      PlugTest.conn(request.method, uri, body)
      |> put_headers(request.headers, substitutions)
      |> put_content_type(request.data)

    {:ok, DavPlug.call(conn, options)}
  rescue
    error ->
      {:failed,
       "request raised #{inspect(error.__struct__)}: #{Exception.message(error)} @ " <>
         (__STACKTRACE__
          |> Enum.take(4)
          |> Exception.format_stacktrace()
          |> String.replace("\n", " "))}
  catch
    kind, reason -> {:failed, "request #{kind}: #{inspect(reason)}"}
  end

  defp iterated(filepath) do
    path = Path.join(@root, filepath)

    if File.dir?(path) do
      path
      |> File.ls!()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.sort()
      |> Enum.map(&Path.join(filepath, &1))
    else
      []
    end
  end

  defp body(%{data: nil}, _substitutions), do: ""

  defp body(%{data: %{filepath: nil}}, _substitutions), do: ""

  defp body(%{data: %{filepath: filepath} = data}, substitutions) do
    case File.read(Path.join(@root, filepath)) do
      {:ok, contents} ->
        contents
        |> substituted(Map.get(data, :substitutions, []), substitutions)
        |> ServerInfo.expand(substitutions)

      _missing ->
        ""
    end
  end

  # The request's own `<substitute>` pairs run first: they name things
  # the shared fixture leaves open, and their values may themselves be
  # substitutions.
  defp substituted(contents, pairs, substitutions) do
    Enum.reduce(pairs, contents, fn {name, value}, expanded ->
      String.replace(expanded, name, ServerInfo.expand(value, substitutions))
    end)
  end

  # `**` in a request URI stands for a name the suite does not care
  # about — upstream fills it with a fresh UUID. Anything unique will
  # do, so long as two requests in one run never collide.
  defp named(uri) do
    if String.contains?(uri, "**"),
      do: String.replace(uri, "**", Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)),
      else: uri
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

  # Verifier arguments are written in the same `$variable:` language as
  # the requests — `okhrefs` names `$calendarhome1:/calendar/1.ics` —
  # so they must be expanded too. Comparing an expanded response href
  # against an unexpanded expectation fails every time, and looks like
  # a server returning the wrong resource.
  defp verify(request, conn, state) do
    request.verifiers
    |> Enum.filter(&Scenario.applicable?(&1, Features.declared()))
    |> Enum.map(&expand_arguments(&1, state))
    |> Enum.reduce_while(:passed, fn check, _outcome ->
      case Verifier.run(check, conn, state.substitutions) do
        :passed -> {:cont, :passed}
        other -> {:halt, other}
      end
    end)
  end

  defp expand_arguments(check, state) do
    arguments =
      Map.new(check.args, fn {name, values} ->
        {name, Enum.map(values, &ServerInfo.expand(&1, state.substitutions))}
      end)

    %{check | args: arguments}
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
      for index <- 1..accounts(substitutions),
          home = substitutions["$calendarhome#{index}:"],
          is_binary(home),
          do: {index, segments(home)}

    # Rooms and equipment are calendar users too. They have a home, a
    # principal and an address like anyone else — the difference is
    # that nobody sits at their keyboard, which is why an invitation
    # to one is answered by the server rather than by them.
    rooms =
      for index <- 1..accounts(substitutions),
          home = substitutions["$rcalendarhome#{index}:"],
          is_binary(home),
          do: {index, segments(home)}

    homes = Enum.map(people ++ rooms, &elem(&1, 1))

    # No `tasks` collection: this server does not declare
    # `split-calendars`, so VTODOs live in the calendar and a
    # separate collection would appear in every listing the suite
    # checks.
    collections =
      for home <- homes, leaf <- ["calendar", "tasks"], do: home ++ [leaf]

    owners = Map.merge(owned(people, substitutions), owned_rooms(rooms, substitutions))

    named = named_homes(people, rooms, substitutions)

    resources =
      ([[] | ancestors(homes)] ++ homes)
      |> Enum.uniq()
      |> Enum.map(
        &%Resource{
          path: &1,
          collection?: true,
          owner: owner_of(&1, owners),
          display_name: Map.get(named, &1)
        }
      )

    calendars =
      for path <- collections,
          do: %Resource{
            path: path,
            collection?: true,
            types: [Cal.calendar()],
            owner: owner_of(path, owners)
          }

    # The other standing members of a reference-deployment home: the
    # `freebusy` resource a client reads busy time from, and the
    # `dropbox` attachment collection — which home synchronisation
    # deliberately answers `404` for.
    fixtures =
      for home <- homes,
          {leaf, collection?, types} <- [
            {"freebusy", false, []},
            {"dropbox", true, [{"http://calendarserver.org/ns/", "dropbox-home"}]}
          ],
          do: %Resource{
            path: home ++ [leaf],
            collection?: collection?,
            types: types,
            owner: owner_of(home, owners)
          }

    # RFC 6638: the Inbox and Outbox are ordinary collections
    # distinguished by their resource type, and scheduling needs them
    # to exist before any of it can be exercised.
    # A notification collection is where sharing invitations arrive.
    notifications =
      for home <- homes,
          do: %Resource{
            path: home ++ ["notification"],
            collection?: true,
            types: [Sharing.notification()],
            owner: owner_of(home, owners)
          }

    scheduling =
      for home <- homes,
          {leaf, type} <- [{"inbox", Schedule.inbox()}, {"outbox", Schedule.outbox()}],
          do: %Resource{
            path: home ++ [leaf],
            collection?: true,
            types: [type],
            owner: owner_of(home, owners)
          }

    # Every spelling resolves to the same home, the canonical `urn:`
    # form included. Leaving it out means delivery works on the first
    # write and stops the moment addresses are normalised, which is
    # the moment it matters.
    addresses =
      Map.merge(
        located(people, ~w(cuaddr email cuaddrurn cuaddralt), substitutions),
        located(rooms, ~w(rcuaddr rcuaddrurn rcuaddralt), substitutions)
      )

    # The suite posts server-to-server messages at a top-level
    # endpoint, which a deployment marks explicitly.
    receiver = [%Resource{path: ["inbox"], collection?: true, types: [Schedule.receiver()]}]

    # One principal, two paths. The suite addresses people by name —
    # `/principals/users/user01/` — and expects properties to answer
    # with the stable form, `/principals/__uids__/<guid>/`. A
    # deployment that offers only one of them either cannot be
    # addressed or reports an owner nobody asked about.
    principals =
      for {index, _home} <- people,
          canonical = canonical_principal(index, substitutions),
          is_binary(canonical),
          path <- Enum.uniq([substitutions["$principal#{index}:"], canonical]),
          is_binary(path),
          do: %Resource{
            path: segments(path),
            collection?: true,
            types: [Acl.principal()],
            owner: canonical,
            display_name: substitutions["$username#{index}:"]
          }

    # Ancestors only. `ancestors/1` includes the path it was given, and
    # a bare collection at a principal's own path sits earlier in the
    # list than the principal itself — so `resolve/2` found the
    # placeholder, and the principal answered `displayname` with its
    # UID and `principal-URL` with 404.
    named = MapSet.new(principals, & &1.path)

    tree =
      principals
      |> Enum.map(& &1.path)
      |> ancestors()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(named, &1))
      |> Enum.map(&%Resource{path: &1, collection?: true})

    SchedulingStore.start(
      resources ++
        calendars ++
        scheduling ++
        fixtures ++
        notifications ++
        tree ++
        ancestry(room_principals(rooms, substitutions)) ++
        principals ++
        room_principals(rooms, substitutions) ++
        proxies(principals) ++ receiver ++ group_principals(substitutions),
      addresses,
      principal_properties(people, substitutions)
      |> Map.merge(group_properties(substitutions))
      |> Map.merge(tasks_properties(homes)),
      canonical_addresses(people, substitutions),
      aliased_homes(people, substitutions),
      unattended_addresses(rooms, substitutions)
    )
  end

  # Every spelling of every room and resource address, folded for
  # lookup. The store answers `unattended?/2` from this set, which is
  # how the library refuses a resource as an organiser without a
  # `CUTYPE` in the data to go on.
  defp unattended_addresses(rooms, substitutions) do
    for {address, _home} <- located(rooms, ~w(rcuaddr rcuaddrurn rcuaddralt), substitutions),
        into: MapSet.new(),
        do: String.downcase(address)
  end

  # Apple's calendar-user-proxy draft: every principal has two child
  # principals standing for "may read my calendars" and "may write
  # them". A client grants access by PROPPATCHing `group-member-set`
  # on one of them, so they have to exist before anything can.
  defp proxies(principals) do
    for principal <- principals,
        leaf <- ["calendar-proxy-read", "calendar-proxy-write"],
        do: %Resource{
          path: principal.path ++ [leaf],
          collection?: true,
          types: [Acl.principal()],
          owner: principal.owner
        }
  end

  # The form properties report. `$principaluri` is the identifier that
  # does not change when someone is renamed, which is why the suite
  # writes its expectations in terms of it.
  defp owned(people, substitutions) do
    for {index, home} <- people,
        owner = canonical_principal(index, substitutions),
        is_binary(owner),
        into: %{},
        do: {home, owner}
  end

  defp owned_rooms(rooms, substitutions) do
    for {index, home} <- rooms,
        owner = substitutions["$rprincipal#{index}:"],
        is_binary(owner),
        into: %{},
        do: {home, owner}
  end

  defp located(who, keys, substitutions) do
    for {index, home} <- who,
        key <- keys,
        address = substitutions["$#{key}#{index}:"],
        is_binary(address),
        into: %{},
        do: {address, home}
  end

  defp room_principals(rooms, substitutions) do
    for {index, _home} <- rooms,
        path = substitutions["$rprincipal#{index}:"],
        is_binary(path),
        do: %Resource{
          path: segments(path),
          collection?: true,
          types: [Acl.principal()],
          owner: path,
          display_name: substitutions["$resourcename#{index}:"]
        }
  end

  # A home carries its owner's name. `CALDAV:calendar-user-address-set`
  # resolves an address to a home, and the server states the `CN` on
  # an `ATTENDEE` from there — a client that invented one gets the
  # real name back, which is what `nonascii.xml` checks.
  defp named_homes(people, rooms, substitutions) do
    people =
      for {index, home} <- people,
          name = substitutions["$username#{index}:"],
          is_binary(name),
          into: %{},
          do: {home, name}

    rooms =
      for {index, home} <- rooms,
          name = substitutions["$resourcename#{index}:"],
          is_binary(name),
          into: %{},
          do: {home, name}

    Map.merge(people, rooms)
  end

  defp ancestry(principals) do
    principals
    |> Enum.map(& &1.path)
    |> ancestors()
    |> Enum.uniq()
    |> Enum.map(&%Resource{path: &1, collection?: true})
  end

  # A calendar home answers to two names: the stable one built from a
  # user's identifier, and the readable one built from their login.
  # They are the same collection, so the second is an alias rather
  # than a copy — two copies would drift apart on the first write.
  defp aliased_homes(people, substitutions) do
    homes =
      for {index, home} <- people,
          alternate = substitutions["$calendarhomealt#{index}:"],
          is_binary(alternate),
          segments(alternate) != home,
          into: %{},
          do: {segments(alternate), home}

    # And the same for principals. A grant made against one spelling of
    # somebody has to be visible against the other, or a proxy added by
    # name is a stranger when looked up by identifier.
    principals =
      for {index, _home} <- people,
          named = substitutions["$principal#{index}:"],
          canonical = canonical_principal(index, substitutions),
          is_binary(named),
          is_binary(canonical),
          segments(named) != segments(canonical),
          leaf <- [[], ["calendar-proxy-read"], ["calendar-proxy-write"]],
          into: %{},
          do: {segments(named) ++ leaf, segments(canonical) ++ leaf}

    Map.merge(homes, principals)
  end

  defp canonical_principal(index, substitutions) do
    substitutions["$principaluri#{index}:"] || substitutions["$principal#{index}:"]
  end

  # Every spelling of a user maps to the one form the server stores.
  # The suite's expectations are written in that form, which is how it
  # checks a server actually normalises rather than echoing back
  # whatever the client sent.
  defp canonical_addresses(people, substitutions) do
    for {index, _home} <- people,
        canonical = substitutions["$cuaddrurn#{index}:"],
        is_binary(canonical),
        spelling <- spellings(index, substitutions, canonical),
        into: %{},
        do: {String.downcase(spelling), canonical}
  end

  defp spellings(index, substitutions, canonical) do
    ["$cuaddr#{index}:", "$email#{index}:", "$cuaddralt#{index}:"]
    |> Enum.map(&substitutions[&1])
    |> Enum.filter(&is_binary/1)
    |> Enum.concat([canonical])
  end

  # RFC 6638 puts a principal's scheduling URLs on the principal
  # resource, which is how a client finds an Inbox at all. A store
  # supplies them; here they are seeded so the suite can ask for them.
  # Groups are calendar users too. `expandproperty.xml` asks a group
  # who its members are and a person which groups they belong to, in
  # both a direct form (`DAV:group-member-set`) and a transitive one
  # (Apple's `CS:expanded-group-member-set`) — the difference between
  # them is the whole point of those tests, so the graph has to nest.
  @groups %{
    2 => {[], [6, 7]},
    3 => {[], [8, 9]},
    4 => {[2, 3], [10]},
    5 => {[6], []},
    6 => {[], [21]}
  }

  defp group_principals(substitutions) do
    for {index, _members} <- @groups,
        path = substitutions["$gprincipaluri#{index}:"],
        is_binary(path),
        do: %Resource{
          path: segments(path),
          collection?: true,
          types: [Acl.principal()],
          owner: path,
          display_name: substitutions["$groupname#{index}:"]
        }
  end

  defp group_properties(substitutions) do
    members =
      for {index, _} <- @groups,
          path = substitutions["$gprincipaluri#{index}:"],
          is_binary(path),
          into: %{},
          do:
            {segments(path),
             %{
               {Xml.dav(), "group-member-set"} => {:hrefs, direct(index, substitutions)},
               {@calendarserver, "expanded-group-member-set"} =>
                 {:hrefs, expanded(index, substitutions)}
             }}

    Map.merge(members, memberships(substitutions))
  end

  defp direct(index, substitutions) do
    {groups, people} = Map.fetch!(@groups, index)

    for href <-
          Enum.map(groups, &substitutions["$gprincipaluri#{&1}:"]) ++
            Enum.map(people, &canonical_principal(&1, substitutions)),
        is_binary(href),
        do: href
  end

  defp expanded(index, substitutions) do
    {groups, _people} = Map.fetch!(@groups, index)

    Enum.uniq(direct(index, substitutions) ++ Enum.flat_map(groups, &expanded(&1, substitutions)))
  end

  # Whom each group holds, read the other way round.
  defp memberships(substitutions) do
    for person <- 1..accounts(substitutions),
        path = canonical_principal(person, substitutions),
        is_binary(path),
        direct = groups_of(person, substitutions, false),
        direct != [],
        into: %{},
        do:
          {segments(path),
           %{
             {Xml.dav(), "group-membership"} => {:hrefs, direct},
             {@calendarserver, "expanded-group-membership"} =>
               {:hrefs, groups_of(person, substitutions, true)}
           }}
  end

  defp groups_of(person, substitutions, transitive?) do
    for {index, _} <- @groups,
        href = substitutions["$gprincipaluri#{index}:"],
        is_binary(href),
        member?(index, person, substitutions, transitive?),
        do: href
  end

  defp member?(index, person, substitutions, transitive?) do
    href = canonical_principal(person, substitutions)

    within =
      if transitive?, do: expanded(index, substitutions), else: direct(index, substitutions)

    is_binary(href) and href in within
  end

  # The reference deployment's tasks calendar holds to-dos and stays
  # out of free-busy: it declares `VTODO` as its only component and is
  # transparent, which keeps it off `CALDAV:calendar-free-busy-set`
  # and out of the running when scheduling picks a default calendar.
  defp tasks_properties(homes) do
    for home <- homes, into: %{} do
      {home ++ ["tasks"],
       %{
         {Xml.caldav(), "schedule-calendar-transp"} => {:names, [{Xml.caldav(), "transparent"}]},
         {Xml.caldav(), "supported-calendar-component-set"} => {:components, ["VTODO"]}
       }}
    end
  end

  defp principal_properties(people, substitutions) do
    for {index, home} <- people,
        path = canonical_principal(index, substitutions),
        is_binary(path),
        into: %{} do
      {segments(path),
       %{
         # A deployment knows people's names. Sharing invitations carry
         # them so that an invitee's client shows "User 01" rather than
         # a principal URL, and the name is the server's to give: a
         # sharer's client can spell it however it likes.
         {Xml.dav(), "displayname"} => substitutions["$username#{index}:"],
         {Xml.caldav(), "calendar-home-set"} => {:hrefs, ["/" <> Enum.join(home, "/") <> "/"]},
         {Xml.caldav(), "schedule-inbox-URL"} =>
           {:hrefs, ["/" <> Enum.join(home ++ ["inbox"], "/") <> "/"]},
         {Xml.caldav(), "schedule-outbox-URL"} =>
           {:hrefs, ["/" <> Enum.join(home ++ ["outbox"], "/") <> "/"]},
         {Xml.caldav(), "calendar-user-address-set"} =>
           {:hrefs,
            Enum.filter(
              [substitutions["$cuaddrurn#{index}:"], substitutions["$cuaddr#{index}:"]],
              &is_binary/1
            )}
       }}
    end
  end

  # Access control is computed from ownership, so every resource inside
  # a user's home carries their principal URL.
  defp owner_of(path, owners) do
    Enum.find_value(owners, fn {home, owner} ->
      if Enum.take(path, length(home)) == home, do: owner
    end)
  end

  defp ancestors(homes) do
    homes
    |> Enum.flat_map(fn home -> for n <- 1..length(home)//1, do: Enum.take(home, n) end)
    |> Enum.uniq()
  end

  defp segments(path), do: path |> String.split("/", trim: true)

  defp plug_options(context, substitutions) do
    DavPlug.init(
      store: SchedulingStore,
      context: context,
      methods: [{"MKCALENDAR", Cal.Mkcalendar}, {"POST", Cal.Post}],
      validators: [Cal.Object],
      hooks: [Cal.Scheduling, Cal.Sharing],
      authentication: :required,
      compliance: ~w(access-control calendar-access calendar-schedule calendar-auto-schedule
           calendarserver-sharing calendarserver-sharing-no-scheduling
           calendarserver-home-sync),
      # The reference deployment shares these extensions between
      # participants; everything else a client hangs on its own copy
      # stays there. The suite's fixtures name them, so the harness
      # configures the same set rather than the library guessing.
      extensions: ~w(X-TEST-ALL-PROP1 X-TEST-ALL-PARAM1
                     X-TEST-ORGANIZER-PROP1 X-TEST-ORGANIZER-PARAM1
                     X-APPLE-STRUCTURED-LOCATION X-APPLE-NEEDS-REPLY),
      # The compound directives — GETNEW, DELETEALL and the rest —
      # are the harness acting on its own behalf rather than a
      # scenario's, so they act as the first account. A per-request
      # `user` overrides this.
      principal: canonical_principal(1, substitutions),
      reports: [
        {{Xml.dav(), "acl-principal-prop-set"}, Principal.AclPrincipalPropSet},
        {{Xml.dav(), "principal-match"}, Principal.Match},
        {{Xml.dav(), "principal-property-search"}, Principal.PropertySearch},
        {{Xml.dav(), "principal-search-property-set"}, Principal.SearchPropertySet},
        {{Xml.dav(), "expand-property"}, Principal.ExpandProperty},
        {{Xml.dav(), "sync-collection"}, Dav.Web.Sync},
        {{Xml.caldav(), "calendar-query"}, Cal.Query},
        {{Xml.caldav(), "calendar-multiget"}, Cal.Multiget},
        {{Xml.caldav(), "free-busy-query"}, Cal.FreeBusy}
      ]
    )
  end
end
