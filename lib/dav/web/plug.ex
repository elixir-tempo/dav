defmodule Dav.Web.Plug do
  @moduledoc """
  WebDAV as a Plug.

  Mounts into any Plug or Phoenix pipeline. Authentication, TLS and
  rate limiting stay in the pipeline where they belong — this handles
  the protocol and nothing else, and is handed an already-resolved
  context.

      forward "/dav", to: Dav.Web.Plug, init_opts: [store: MyStore, context: repo]

  ### What it answers today

  `OPTIONS`, advertising the compliance classes actually implemented,
  and `PROPFIND` with `Depth: 0` or `1`. Everything else is `405` with
  an honest `Allow` header rather than a pretence.

  **Class 1 only: there is no locking.** RFC 4918 permits it, most
  clients tolerate it, and `LOCK` is a large fraction of the
  specification for a feature a read-mostly server does not need.
  Advertising `DAV: 1, 2` without implementing `LOCK` would be worse
  than not advertising it, because a client that believes it holds a
  lock behaves differently.

  """

  @behaviour Plug

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Web.Acl
  alias Dav.Web.Hook
  alias Dav.Web.Properties
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @multistatus 207

  @doc """
  Build the plug's options.

  ### Options

  * `:store` is the `Dav.Web.Store` implementation. Required.

  * `:context` is passed to every store callback — the authenticated
    principal, a tenant, a repository handle.

  * `:principal` is the principal URL of whoever is making the
    request, or `nil` when nobody is authenticated. It is what
    `DAV:current-user-principal` reports.

  * `:authentication` is `:optional`, the default, or `:required`. A
    server that requires it answers `401` when `:principal` is `nil`,
    so an anonymous client is told to authenticate rather than that
    the resource is forbidden to it.

  * `:compliance` lists the compliance classes to advertise in the
    `DAV` header beyond `1` — `calendar-access` and the rest. A class
    is a promise about behaviour, so the deployment states it.

  * `:extensions` names the `X-` properties and parameters that
    travel with a scheduling message. Which extensions are shared
    rather than private is a matter of local agreement between
    clients, so a deployment states it; the default carries only
    `X-APPLE-STRUCTURED-LOCATION`.

  * `:client_repairs` lists the `User-Agent` strings of clients whose
    writes this server repairs — currently the `TRANSP` a client
    leaves inconsistent with its own participation. Matched exactly,
    because client versions differ by a character and a near match is
    a different build. Empty by default: repairing what a client sent
    is a deployment's decision about clients it knows, not a rule of
    the protocol.

  * `:principals` lists the hrefs of the collections that hold this
    deployment's principals, reported as RFC 3744's
    `DAV:principal-collection-set` on every resource. Empty by
    default, and the property is simply absent then.

  * `:reports`, `:validators`, `:hooks` and `:methods` are the four
    extension points, each a list the request dispatches through.

  ### Returns

  * The options map the plug is called with.

  ### Examples

      iex> options = Dav.Web.Plug.init(store: Dav.Web.Store)
      iex> options.authentication
      :optional

      iex> options = Dav.Web.Plug.init(store: Dav.Web.Store, authentication: :required)
      iex> options.authentication
      :required

  """
  @impl Plug
  def init(options) do
    %{
      store: Keyword.fetch!(options, :store),
      context: Keyword.get(options, :context),
      reports: Map.new(Keyword.get(options, :reports, [])),
      validators: Keyword.get(options, :validators, []),
      hooks: Keyword.get(options, :hooks, []),
      principal: Keyword.get(options, :principal),
      authentication: Keyword.get(options, :authentication, :optional),
      extensions: Keyword.get(options, :extensions),
      compliance: Keyword.get(options, :compliance, []),
      methods: Map.new(Keyword.get(options, :methods, [])),
      well_known: Map.new(Keyword.get(options, :well_known, [])),
      administrators: Keyword.get(options, :administrators, []),
      principals: Keyword.get(options, :principals, []),
      client_repairs: Keyword.get(options, :client_repairs, [])
    }
  end

  # What the `DAV` header advertises. `1` is this server; anything
  # further is the deployment's to state, because a compliance class
  # is a promise about behaviour the base cannot check — advertising
  # `calendar-access` without the CalDAV extension installed tells a
  # client to send requests nothing will answer.
  defp compliance(%{compliance: []}), do: "1"

  defp compliance(%{compliance: classes}), do: Enum.join(["1" | classes], ", ")

  # The `Allow` header is built from what the store can actually do.
  # A read-only store gets a read-only server, and never advertises a
  # method that would fail — which matters more than it sounds, because
  # a client that believes `PUT` works behaves differently from one
  # that knows it does not.
  defp allowed(%{store: store} = options) do
    optional =
      for {capability, method} <- [
            put: "PUT",
            delete: "DELETE",
            mkcol: "MKCOL",
            patch: "PROPPATCH"
          ],
          Store.supports?(store, capability),
          do: method

    read = if Store.supports?(store, :read), do: ["GET", "HEAD"], else: []

    registered = Map.keys(Map.get(options, :methods, %{}))

    Enum.join(["OPTIONS", "PROPFIND", "REPORT"] ++ read ++ optional ++ registered, ", ")
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, %{} = options) do
    case Store.segments(conn.request_path) do
      # RFC 6764: `/.well-known/caldav` is how a client holding only a
      # hostname finds the service — and it happens before anyone has
      # credentials, so no challenge stands in front of it.
      [".well-known" | service] ->
        discovered(conn, service, options)

      _elsewhere ->
        if authenticated?(options) or anonymous_endpoint?(conn, options),
          do: dispatch(conn.method, conn, options |> scoped() |> repairing(conn)),
          else: challenge(conn)
    end
  end

  # The `.well-known` collection itself answers as an empty place: a
  # `GET` has nothing to show and a `PROPFIND` one resource to name.
  # A registered service under it answers `301` to where the service
  # actually lives.
  defp discovered(conn, [], _options) do
    case conn.method do
      "GET" ->
        send_resp(conn, 200, "")

      "PROPFIND" ->
        {:ok, _body, conn} = read_body(conn)

        row = {"/.well-known/", [{"HTTP/1.1 200 OK", [{{Xml.dav(), "resourcetype"}, nil}]}]}

        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(207, Xml.multistatus([row]))

      _other ->
        send_resp(conn, 405, "")
    end
  end

  defp discovered(conn, [service | _below], options) do
    case Map.get(options.well_known, service) do
      nil -> send_resp(conn, 404, "")
      target -> conn |> put_resp_header("location", target) |> send_resp(301, "")
    end
  end

  # A server-to-server receiver takes messages from *other servers*,
  # which hold no account here — requiring a user on it would refuse
  # the one caller it exists for. Every other resource still demands
  # one when the deployment does.
  defp anonymous_endpoint?(conn, %{store: store, context: context}) do
    case store.resolve(Store.segments(conn.request_path), context) do
      {:ok, resource} -> Enum.any?(resource.types, &(&1 == receiver_type()))
      _absent -> false
    end
  end

  defp receiver_type, do: {"urn:ietf:params:xml:ns:ischedule", "receiver"}

  # Asked once, at the edge, so every callback below sees the same
  # context. A store that holds shared data needs to know who is
  # asking — a calendar shared between two people has a part they both
  # see and a part each sees alone — and only the store knows how to
  # say "the same store, as seen by this person".
  defp scoped(%{store: store, context: context} = options) do
    if Store.supports?(store, :scope) do
      %{options | context: store.scope(context, Map.get(options, :principal))}
    else
      options
    end
  end

  # A deployment that requires authentication answers `401` with a
  # challenge rather than `403`. The difference is "I do not know who
  # you are" against "I know, and no" — a client that cannot tell them
  # apart either retries forever with credentials the server has
  # already refused, or gives up on ones it never offered.
  defp authenticated?(%{authentication: :required, principal: nil}), do: false
  defp authenticated?(_options), do: true

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="dav"))
    |> send_resp(401, "")
  end

  defp dispatch("OPTIONS", conn, options) do
    conn
    |> put_resp_header("dav", compliance(options))
    |> put_resp_header("allow", allowed(options))
    |> put_resp_header("ms-author-via", "DAV")
    |> send_resp(200, "")
  end

  defp dispatch(method, conn, options) when method in ["GET", "POST"] do
    if method == "POST" and
         List.last(Store.segments(conn.request_path)) == ";add-member" do
      add_member(conn, options)
    else
      case acted(conn, options) do
        {:ok, conn} -> conn
        :unhandled -> undirected(method, conn, options)
      end
    end
  end

  defp dispatch("PROPFIND", conn, options), do: propfind(conn, options)

  defp dispatch("REPORT", conn, options), do: report(conn, options)

  defp dispatch(method, conn, options) when method in ["GET", "HEAD"],
    do: get(method, conn, options)

  defp dispatch("PUT", conn, options), do: put(conn, options)

  defp dispatch("DELETE", conn, options), do: delete(conn, options)

  defp dispatch("MKCOL", conn, options), do: mkcol(conn, options)

  defp dispatch("PROPPATCH", conn, options), do: proppatch(conn, options)

  defp dispatch("COPY", conn, options), do: transfer(:copy, conn, options)

  defp dispatch("MOVE", conn, options), do: transfer(:move, conn, options)

  # An extension's method, if one is registered for it. Checked last,
  # so an extension cannot quietly take over a method the base defines.
  defp dispatch(method, conn, options) do
    case Map.fetch(options.methods, method) do
      {:ok, handler} -> handler.call(conn, Store.segments(conn.request_path), options)
      :error -> refuse(conn, options)
    end
  end

  # RFC 5995: a `POST` to a collection's `DAV:add-member` URL stores a
  # new member without the client choosing its name — the server picks
  # one and answers with `Location`. Everything else is a `PUT`: the
  # same validation, the same hooks, the same preferences.
  defp add_member(conn, options) do
    parent = conn.request_path |> Store.segments() |> Enum.drop(-1)
    name = "member-#{System.unique_integer([:positive])}.ics"
    location = "/" <> Enum.map_join(parent ++ [name], "/", &URI.encode/1)

    conn
    |> Map.put(:request_path, location)
    |> put_resp_header("location", location)
    |> put(options)
  end

  # What a `GET` or `POST` means when nothing claimed its `action`:
  # a `GET` is a read, and a `POST` belongs to whichever extension
  # registered for it.
  defp undirected("GET", conn, options), do: get("GET", conn, options)

  defp undirected(method, conn, options) do
    case Map.fetch(options.methods, method) do
      {:ok, handler} -> handler.call(conn, Store.segments(conn.request_path), options)
      :error -> refuse(conn, options)
    end
  end

  defp refuse(conn, options) do
    conn
    |> put_resp_header("allow", allowed(options))
    |> send_resp(405, "")
  end

  ## --- reading and writing ----------------------------------------

  defp get(method, conn, options) do
    with :ok <- capable(options, :read),
         {:ok, resource} <- resolve(conn, options),
         :ok <- permitted(resource, options),
         {:ok, type, body} <- retrieved(resource, options) do
      conn
      |> etag(resource)
      |> contributed_headers(resource, options)
      |> put_resp_content_type(type)
      |> send_resp(200, if(method == "HEAD", do: "", else: body))
    else
      {:error, :unsupported} ->
        refuse(conn, options)

      # An extension guarding an area answers for its misses too — a
      # `404` inside somebody's private space confirms what is not
      # there.
      {:error, :not_found} ->
        absent = %Resource{path: Store.segments(conn.request_path)}

        case permitted(absent, options) do
          :ok -> send_resp(conn, 404, "")
          {:error, :forbidden} -> precondition(conn, {Xml.dav(), "need-privileges"})
        end

      {:error, :forbidden} ->
        precondition(conn, {Xml.dav(), "need-privileges"})

      # RFC 4918 leaves GET on a collection to the server, and no
      # extension offered a rendering for this one.
      {:error, :is_collection} ->
        send_resp(conn, 405, "")
    end
  end

  # Whether this client is one the deployment repairs after. Recorded
  # once, here, so a hook deciding whether to correct what it was sent
  # does not go looking through the request for the answer.
  defp repairing(options, conn) do
    agent = conn |> get_req_header("user-agent") |> List.first()

    Map.put(options, :repairing?, agent in Map.get(options, :client_repairs, []))
  end

  # An extension holding private material refuses the read here —
  # attachments are the owner's alone.
  defp permitted(resource, options) do
    options.hooks
    |> Enum.filter(&implements?(&1, :readable, 2))
    |> Enum.find_value(:ok, fn hook ->
      case hook.readable(resource, options) do
        :ok -> nil
        refusal -> refusal
      end
    end)
  end

  defp put(conn, options) do
    {:ok, body, conn} = read_body(conn)
    type = conn |> get_req_header("content-type") |> List.first() |> media_type()
    path = Store.segments(conn.request_path)

    with :ok <- capable(options, :put),
         :ok <- writable(path, options),
         :ok <- Hook.creation(path, :document, options),
         :ok <- schedule_tag_matches(conn, path, options),
         :ok <- entity_tag_matches(conn, path, options),
         :ok <- validate(body, path, options, type),
         previous = contents(path, options),
         {:ok, outcome, resource} <- options.store.put(path, body, type, options.context) do
      written(resource, body, previous, path, merging?(conn), options)

      settled = settled(resource, path, options)

      # RFC 4791 section 5.3.4: a server that changed what it was
      # given must not answer with an `ETag`, because the tag would
      # name a copy the client does not have. A hook that rewrites —
      # adding the calendar's default alarm — makes exactly that
      # difference.
      conn =
        if rewritten?(path, body, options),
          do: contributed_headers(conn, settled, options),
          else: conn |> etag(settled) |> contributed_headers(settled, options)

      # RFC 7240 `return=representation`: the answer carries what was
      # actually stored — which the hooks may have rewritten — so the
      # client need not fetch it back to learn what its write became.
      written_response(conn, settled, outcome, options)
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :schedule_tag} -> refused_write(conn, path, options)
      {:error, :entity_tag} -> refused_write(conn, path, options)
      # A missing parent is a conflict, not an invitation to create it.
      {:error, :conflict} -> send_resp(conn, 409, "")
      {:error, :collection} -> send_resp(conn, 403, "")
      {:error, :forbidden} -> send_resp(conn, 403, "")
      {:error, :method_not_allowed} -> send_resp(conn, 405, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # Compared as content, not as bytes: a store that returns `CRLF`
  # where the client sent `LF` has changed nothing anybody can read,
  # and answering that as a rewrite would withhold the `ETag` from
  # every ordinary write.
  defp rewritten?(path, body, options) do
    case contents(path, options) do
      stored when is_binary(stored) -> lines(stored) != lines(body)
      _unreadable -> false
    end
  end

  defp lines(body), do: body |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))

  # A conditional write that failed still answers `return=representation`
  # — with the copy that *won*: the client's next move needs the current
  # state, and this spares it the `GET`.
  defp written_response(conn, settled, outcome, options) do
    if preferences(conn).representation do
      represented(conn, settled, outcome, options)
    else
      send_resp(conn, if(outcome == :created, do: 201, else: 204), "")
    end
  end

  defp refused_write(conn, path, %{store: store, context: context} = options) do
    with true <- preferences(conn).representation,
         {:ok, current} <- store.resolve(path, context),
         true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(current, context) do
      conn
      |> etag(current)
      |> contributed_headers(current, options)
      |> put_resp_header("content-location", Resource.href(current))
      |> put_resp_content_type(current.content_type || "text/calendar", "utf-8")
      |> send_resp(412, IO.iodata_to_binary(data))
    else
      _plain_refusal -> send_resp(conn, 412, "")
    end
  end

  defp represented(conn, settled, outcome, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(settled, context) do
      conn
      |> put_resp_header("content-location", Resource.href(settled))
      |> put_resp_header("preference-applied", "return=representation")
      |> put_resp_content_type(settled.content_type || "text/calendar", "utf-8")
      |> send_resp(if(outcome == :created, do: 201, else: 200), IO.iodata_to_binary(data))
    else
      _unreadable -> send_resp(conn, if(outcome == :created, do: 201, else: 204), "")
    end
  end

  # What the store holds once the hooks have finished with it. They
  # may rewrite what was just written — implicit scheduling stamps its
  # own parameters into the organiser's copy — so the resource handed
  # back by the write describes a version that no longer exists.
  # Reporting its `ETag` gives the client a validator that is already
  # stale, and their next conditional request is refused for a change
  # the server made itself.
  defp settled(resource, path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, %Resource{} = current} -> current
      _gone -> resource
    end
  end

  # The media type as the server states it. RFC 9110 allows optional
  # whitespace before a parameter, so `text/calendar; charset=utf-8`
  # and `text/calendar;charset=utf-8` are the same type written two
  # ways — and a client that stored one and read back the other has no
  # way to tell whether the server changed it.
  defp media_type(nil), do: nil

  defp media_type(type) do
    case String.split(type, ";") do
      [only] -> String.trim(only)
      [base | parameters] -> Enum.map_join([base | parameters], ";", &String.trim/1)
    end
  end

  # A collection is not a document: `PUT` over one would replace a
  # whole tree with a body, so it is refused rather than obeyed.
  defp writable(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, %Resource{collection?: true}} -> {:error, :collection}
      _absent_or_document -> :ok
    end
  end

  defp held_by(%Resource{collection?: false}, _options), do: []

  # All the way down. A calendar home may hold calendars inside
  # collections, and deleting the outer one takes every invitation
  # under it with it — the attendees have to hear about all of them,
  # not only those that happened to sit at the top.
  defp held_by(%Resource{} = collection, %{store: store, context: context} = options) do
    case store.children(collection, context) do
      {:ok, children} ->
        {nested, objects} = Enum.split_with(children, & &1.collection?)

        held =
          for child <- objects,
              body = contents(child, options),
              is_binary(body),
              do: {child, body, collection}

        held ++ Enum.flat_map(nested, &held_by(&1, options))

      _nothing ->
        []
    end
  end

  defp removed(resource, body, properties, options) do
    withdrawn(resource, body, parent(resource.path, options), options, properties)
  end

  # The collection is named rather than looked up: by the time a
  # member of a deleted calendar is reported, the calendar it belonged
  # to is gone, and a hook asked whether it applies to `nil` says no.
  defp withdrawn(resource, body, collection, options, properties \\ %{}) do
    change = %{
      resource: resource,
      body: body,
      previous: body,
      collection: collection,
      properties: properties
    }

    for hook <- options.hooks,
        concerns?(hook, resource, collection),
        implements?(hook, :deleted, 2),
        do: hook.deleted(change, options)

    :ok
  end

  # A hook hears about a deletion when it applies to the collection the
  # resource was in — and, when a collection is itself deleted, when it
  # applies to *that* collection. Deleting a shared calendar has to
  # withdraw its invitations, and the calendar's parent is a plain home
  # that no sharing hook claims.
  defp concerns?(hook, %Resource{collection?: true} = resource, collection) do
    hook.applies?(collection) or hook.applies?(resource)
  end

  defp concerns?(hook, _resource, collection), do: hook.applies?(collection)

  # What is there now, read before a write replaces it. A hook that
  # must tell a significant change from a trivial one has no other way
  # to see what the resource used to hold.
  defp contents(path, options) when is_list(path) do
    case options.store.resolve(path, options.context) do
      {:ok, resource} -> contents(resource, options)
      _absent -> nil
    end
  end

  defp contents(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(resource, context) do
      IO.iodata_to_binary(data)
    else
      _unreadable -> nil
    end
  end

  # A hook may add headers to a response about a resource — CalDAV's
  # `Schedule-Tag` is the case this exists for.
  # RFC 6638 section 8.3. `If-Match` asks "has anything about this
  # resource changed"; `If-Schedule-Tag-Match` asks the narrower
  # question "has anything *the attendees agreed to* changed", so a
  # client may write its own private edits without losing a race
  # against an unrelated change. `*` matches any existing tag.
  defp schedule_tag_matches(conn, path, options) do
    case get_req_header(conn, "if-schedule-tag-match") do
      [] ->
        :ok

      [wanted | _rest] ->
        if wanted == "*" or wanted == current_schedule_tag(path, options),
          do: :ok,
          else: {:error, :schedule_tag}
    end
  end

  # RFC 7232 sections 3.1 and 3.2. `If-Match` says "only if this is
  # still what I last saw", and `If-None-Match: *` says "only if it is
  # not there at all" — the second is how a client creates a resource
  # without racing another that is creating the same one. Both answer
  # `412` rather than overwriting, because a lost update is worse than
  # a refused request.
  defp entity_tag_matches(conn, path, options) do
    current = current_etag(path, options)
    if_match = get_req_header(conn, "if-match")

    cond do
      not (matched?(if_match, current) or schedule_matched?(if_match, path, options)) ->
        {:error, :entity_tag}

      not unmatched?(get_req_header(conn, "if-none-match"), current) ->
        {:error, :entity_tag}

      true ->
        :ok
    end
  end

  # RFC 6638 section 3.2.10. On a scheduling object the `ETag` moves
  # when the server applies another attendee's reply, though nothing
  # the client's copy states has changed. The tags accumulated since
  # the `Schedule-Tag` last changed still satisfy `If-Match`; the
  # ledger is kept by the scheduling hook and starts over whenever
  # the tag itself moves.
  defp schedule_matched?([wanted | _rest], path, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         {:ok, resource} <- store.resolve(path, context),
         %{} = properties <- store.properties(resource, context),
         listed when is_binary(listed) <-
           Map.get(properties, {Xml.caldav(), "schedule-etags"}) do
      known = String.split(listed, " ")

      wanted
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 in known))
    else
      _no_ledger -> false
    end
  end

  defp schedule_matched?(_headers, _path, _options), do: false

  defp matched?([], _current), do: true
  defp matched?(_headers, nil), do: false
  defp matched?([wanted | _rest], current), do: wanted == "*" or listed?(wanted, current)

  defp unmatched?([], _current), do: true
  defp unmatched?(_headers, nil), do: true
  defp unmatched?([wanted | _rest], current), do: wanted != "*" and not listed?(wanted, current)

  # A condition may carry several tags, and a weak comparison ignores
  # the `W/` prefix a proxy may have added.
  defp listed?(wanted, current) do
    wanted
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.member?(String.replace_prefix(current, "W/", ""))
  end

  defp current_etag(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, %Resource{etag: etag}} -> etag
      _absent -> nil
    end
  end

  defp current_schedule_tag(path, options) do
    with {:ok, resource} <- options.store.resolve(path, options.context),
         collection = parent(resource.path, options),
         {_name, value} <-
           options.hooks
           |> Enum.filter(&implements?(&1, :headers, 3))
           |> Enum.flat_map(& &1.headers(resource, collection, options))
           |> Enum.find(fn {name, _value} -> name == "schedule-tag" end) do
      value
    else
      _absent -> nil
    end
  end

  # Apple's extensions hang several operations off an `action` query
  # parameter rather than a method of their own. A request without one
  # is dispatched normally, and one whose action nothing recognises is
  # too — the parameter is not a promise that the server implements it.
  defp acted(conn, options) do
    with action when is_binary(action) <- action_of(conn),
         {:ok, resource} <- resolve(conn, options) do
      options.hooks
      |> Enum.filter(&implements?(&1, :action, 4))
      |> Enum.find_value(:unhandled, &claimed(&1, action, conn, resource, options))
    else
      _no_action_or_resource -> :unhandled
    end
  end

  defp claimed(hook, action, conn, resource, options) do
    case hook.action(action, conn, resource, options) do
      {:ok, conn} -> {:ok, conn}
      :unhandled -> nil
    end
  end

  defp action_of(%Plug.Conn{query_string: query}) do
    query |> URI.decode_query() |> Map.get("action")
  end

  defp contributed_headers(conn, resource, options) do
    collection = parent(resource.path, options)

    options.hooks
    |> Enum.filter(&implements?(&1, :headers, 3))
    |> Enum.flat_map(& &1.headers(resource, collection, options))
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

  # What a collection *does* when written to is its business too:
  # storing an event with attendees has to deliver the invitations
  # (RFC 6638 section 3), and a hook cannot fail the write that
  # triggered it.
  defp written(resource, body, previous, path, merging, options) do
    collection = parent(path, options)

    change = %{
      resource: resource,
      body: body,
      previous: previous,
      collection: collection,
      merge: merging
    }

    Hook.saving(change, options)
  end

  # RFC 6638 section 3.2.10: a write conditional on the Schedule-Tag
  # says "merge my changes" rather than "replace what is there" — the
  # client knows its copy may be stale in ways it never agreed to, and
  # asks the server to reconcile rather than refuse.
  defp merging?(conn), do: get_req_header(conn, "if-schedule-tag-match") != []

  # What a collection may contain is the collection's business, not
  # this module's: `Dav.Cal.Object` enforces RFC 4791's restrictions on
  # calendar collections without the base learning what a calendar is.
  defp validate(body, path, options, content_type) do
    collection = parent(path, options)
    options = Map.put(options, :content_type, content_type)

    options.validators
    |> Enum.filter(& &1.applies?(collection))
    |> Enum.reduce_while(:ok, fn validator, _outcome ->
      case validator.validate(body, collection, path, options) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  defp parent(path, %{store: store, context: context}) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, resource} -> resource
      _absent -> nil
    end
  end

  defp delete(conn, options) do
    with :ok <- capable(options, :delete),
         {:ok, resource} <- resolve(conn, options),
         :ok <- removable(resource, options),
         :ok <- schedule_tag_matches(conn, resource.path, options),
         :ok <- entity_tag_matches(conn, resource.path, options),
         # Read before removing: afterwards there is nothing left to
         # read, and a hook that must know what the resource held has
         # no way to find out.
         held = contents(resource, options) || "",
         members = held_by(resource, options),
         # Read for the same reason: a hook acting on what the resource
         # *was* cannot ask the store once it is gone. Deleting a shared
         # calendar has to withdraw the invitations recorded on it.
         properties = stored(resource, options),
         :ok <- options.store.delete(resource, options.context) do
      removed(resource, held, properties, options)

      # A collection has no body of its own, so deleting one would tell
      # the hooks nothing about what it held. Deleting a calendar full
      # of invitations has to withdraw every one of them, and the
      # attendees only learn of it through the objects that were in
      # there.
      # Each member is reported against the calendar it was actually
      # in, not the collection the request named: a hook asked about
      # the folder above a calendar says it does not apply, and the
      # invitations inside would go unwithdrawn.
      for {member, body, holder} <- members, do: withdrawn(member, body, holder, options)
      send_resp(conn, 204, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :schedule_tag} -> send_resp(conn, 412, "")
      {:error, :entity_tag} -> send_resp(conn, 412, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # An extension may know a removal is not the requester's to make —
  # a sharee deleting an organiser's meeting — where plain access
  # control sees only write permission.
  defp removable(resource, options) do
    collection = parent(resource.path, options)

    options.hooks
    |> Enum.filter(&implements?(&1, :removable, 3))
    |> Enum.find_value(:ok, fn hook ->
      case hook.removable(resource, collection, options) do
        :ok -> nil
        {:error, _failed} = refusal -> refusal
      end
    end)
  end

  defp mkcol(conn, options) do
    {:ok, body, conn} = read_body(conn)

    path = Store.segments(conn.request_path)

    with :ok <- capable(options, :mkcol),
         :ok <- no_body(body),
         :ok <- Hook.creation(path, :collection, options),
         :ok <- nestable(path, options),
         {:ok, _resource} <- options.store.mkcol(path, options.context) do
      send_resp(conn, 201, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      # RFC 4918 reserves a body for extended MKCOL, which this is not.
      {:error, :body} -> send_resp(conn, 415, "")
      {:error, :exists} -> send_resp(conn, 405, "")
      {:error, :forbidden} -> send_resp(conn, 403, "")
      {:error, :method_not_allowed} -> send_resp(conn, 405, "")
      {:error, :conflict} -> send_resp(conn, 409, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # Whether a collection may be created here is the parent collection's
  # business, and a calendar collection says no — RFC 4791 section 4.2.
  # The rule lives with the validators so that this module keeps
  # knowing nothing about calendars.
  defp nestable(path, options) do
    collection = parent(path, options)

    options.validators
    |> Enum.filter(& &1.applies?(collection))
    |> Enum.reduce_while(:ok, fn validator, _outcome ->
      case validator.permit_collection(collection) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  # "A 201 Created response SHOULD include a Location header" — a
  # client that created a resource should not have to guess where it
  # ended up.
  defp capable(%{store: store}, capability) do
    if Store.supports?(store, capability), do: :ok, else: {:error, :unsupported}
  end

  # RFC 4918 leaves GET on a collection to the server; an extension
  # may render one — a calendar rolled up into a single object — and
  # a collection nothing renders is refused.
  defp retrieved(%Resource{collection?: true} = collection, options) do
    case Hook.rendering(collection, options) do
      {:ok, type, body} -> {:ok, type, body}
      :skip -> {:error, :is_collection}
    end
  end

  defp retrieved(resource, options) do
    with {:ok, held} <- options.store.read(resource, options.context),
         {:ok, body} <- Hook.disclosure(resource, IO.iodata_to_binary(held), options) do
      {:ok, resource.content_type || "application/octet-stream", body}
    end
  end

  defp no_body(""), do: :ok
  defp no_body(_body), do: {:error, :body}

  defp etag(conn, %Resource{etag: nil}), do: conn
  defp etag(conn, %Resource{etag: etag}), do: put_resp_header(conn, "etag", etag)

  ## --- PROPFIND ---------------------------------------------------

  defp propfind(conn, options) do
    {:ok, body, conn} = read_body(conn)

    # Resolved before the depth is judged: a `PROPFIND` naming
    # something that is not there is answered `404`, whatever depth it
    # asked for. Refusing the depth of a request for a resource that
    # does not exist tells the client about the wrong problem.
    with {:ok, request} <- Xml.parse_propfind(body),
         {:ok, resource} <- resolve(conn, options),
         {:ok, depth} <- finite(depth(conn, {:ok, :infinity})),
         :ok <- permitted(resource, options),
         :ok <- changed_since(conn, resource),
         {:ok, resources} <- gather(resource, depth, options) do
      prefer = preferences(conn)

      resources =
        if prefer.noroot and depth > 0 and length(resources) > 1,
          do: tl(resources),
          else: resources

      conn |> stamped(resource) |> respond(resources, request, options, prefer)
    else
      {:error, :malformed} -> send_resp(conn, 400, "")
      {:error, :bad_depth} -> send_resp(conn, 400, "")
      {:error, :depth_infinity} -> precondition(conn, {Xml.dav(), "propfind-finite-depth"})
      {:error, :not_found} -> absent(conn, options)
      {:error, :forbidden} -> precondition(conn, {Xml.dav(), "need-privileges"})
      {:error, :not_modified} -> send_resp(conn, 304, "")
    end
  end

  # A missing resource usually answers `404` — but an extension
  # holding private material may refuse to say even that much, the
  # same consultation the `GET` path makes.
  defp absent(conn, options) do
    missing = %Resource{path: Store.segments(conn.request_path)}

    case permitted(missing, options) do
      :ok -> send_resp(conn, 404, "")
      {:error, :forbidden} -> precondition(conn, {Xml.dav(), "need-privileges"})
    end
  end

  # RFC 7232 section 3.3: a conditional request for something that has
  # not changed is answered `304`, not repeated in full. A client
  # polling a collection for changes asks exactly this way, and
  # answering with the whole listing each time is the difference
  # between a poll that costs a header and one that costs the
  # collection.
  defp changed_since(conn, %Resource{modified_at: %DateTime{} = modified}) do
    with [value | _rest] <- get_req_header(conn, "if-modified-since"),
         {:ok, since} <- Properties.from_http_date(value),
         :gt <- DateTime.compare(since, DateTime.truncate(modified, :second)) do
      {:error, :not_modified}
    else
      :eq -> {:error, :not_modified}
      _changed_or_unconditional -> :ok
    end
  end

  defp changed_since(_conn, _resource), do: :ok

  # The header the conditional request will send back. Without it a
  # client has nothing to be conditional *about*, and asks for the
  # whole collection every time.
  defp stamped(conn, %Resource{modified_at: %DateTime{} = modified}) do
    put_resp_header(conn, "last-modified", Properties.http_date(modified))
  end

  defp stamped(conn, _resource), do: conn

  # `Depth: infinity` is refused rather than served. RFC 4918 section
  # 9.1 allows a server to refuse it, and answering it over an
  # unbounded tree is a denial of service with a specification behind
  # it.
  #
  # The default when the header is absent is *not* the same for every
  # method, and getting it wrong is invisible until a client omits the
  # header:
  #
  # * PROPFIND — "Servers SHOULD treat a request without a Depth
  #   header as if a `Depth: infinity` header was included" (RFC 4918
  #   section 9.1), so an absent header is refused exactly as an
  #   explicit `infinity` is.
  #
  # * REPORT — "If no Depth header is included, Depth:0 is assumed"
  #   (RFC 3253 section 3.6).
  # * REPORT — "If no Depth header is included, Depth:0 is assumed"
  #   (RFC 3253 section 3.6), and `infinity` is permitted: RFC 4791
  #   section 7.8 lets a `calendar-query` search a whole tree, so
  #   refusing it there would refuse a documented request.
  defp depth(conn, absent) do
    case get_req_header(conn, "depth") do
      [] -> absent
      ["0"] -> {:ok, 0}
      ["1"] -> {:ok, 1}
      [other] -> infinity(other)
      _repeated -> {:error, :bad_depth}
    end
  end

  defp infinity(value) do
    if String.downcase(value) == "infinity", do: {:ok, :infinity}, else: {:error, :bad_depth}
  end

  # PROPFIND is the one place infinity is refused, and it refuses it by
  # name so a client learns the rule rather than the outcome.
  defp finite({:ok, :infinity}), do: {:error, :depth_infinity}
  defp finite(other), do: other

  defp resolve(conn, %{store: store, context: context}) do
    store.resolve(Store.segments(conn.request_path), context)
  end

  defp gather(resource, 0, _options), do: {:ok, [resource]}

  defp gather(%Resource{collection?: false} = resource, _depth, _options) do
    {:ok, [resource]}
  end

  defp gather(%Resource{} = collection, _depth, %{store: store, context: context} = options) do
    {:ok, children} = store.children(collection, context)

    {:ok, [collection | Enum.reject(children, &Hook.concealed?(&1, options))]}
  end

  ## --- REPORT -----------------------------------------------------

  defp report(conn, options) do
    {:ok, body, conn} = read_body(conn)
    options = Map.put(options, :minimal, minimal?(conn))

    with {:ok, name} <- Xml.report_name(body),
         {:ok, depth} <- depth(conn, {:ok, 0}),
         {:ok, resource} <- resolve(conn, options),
         {:ok, handler} <- handler(name, options),
         {:ok, answer} <- handler.run(resource, body, depth, options) do
      answer(conn, answer)
    else
      {:error, :unsupported_report} ->
        precondition(conn, {Xml.dav(), "supported-report"})

      {:error, :malformed} ->
        send_resp(conn, 400, "")

      {:error, :bad_depth} ->
        send_resp(conn, 400, "")

      {:error, :depth_infinity} ->
        send_resp(conn, 403, "")

      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, :forbidden} ->
        send_resp(conn, 403, "")

      # A report this server understands but cannot carry out in the
      # form asked for. "Not implemented" says so; refusing it as
      # malformed would have the client correcting a body that is
      # perfectly well formed.
      {:error, :not_implemented} ->
        send_resp(conn, 501, "")

      {:error, {_namespace, _local} = failed} ->
        precondition(conn, failed)
    end
  end

  # Most reports answer as a `207 Multi-Status`, and this library
  # writes the XML so that they all answer alike. Not all of them can:
  # a `free-busy-query` computes one value across a whole collection,
  # not a fact about each resource in it, and returns a single
  # iCalendar object with a `200`. A seam that only allowed the
  # multistatus shape would exclude a report the specification marks
  # REQUIRED.
  defp answer(conn, {:body, content_type, body}) do
    conn
    |> put_resp_content_type(content_type, "utf-8")
    |> send_resp(200, body)
  end

  # A `sync-collection` answer carries the new token on the root
  # element itself, beside the responses rather than within one.
  defp answer(conn, {:multistatus, responses, trailing}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(@multistatus, Xml.multistatus(responses, trailing))
  end

  defp answer(conn, responses) when is_list(responses) do
    multistatus(conn, trimmed_missing(responses, minimal?(conn)))
  end

  # RFC 7240: the `Prefer` header carries comma-separated preferences,
  # and ones this server does not recognise are ignored rather than
  # refused. `return=minimal` spares the client the `404` propstats
  # naming what it asked for and the resource lacks; `depth-noroot`
  # spares it the target's own response in a `Depth: 1` listing;
  # `return=representation` answers a write with the stored result.
  defp preferences(conn) do
    stated =
      conn
      |> get_req_header("prefer")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    %{
      minimal: "return=minimal" in stated or brief?(conn),
      noroot: "depth-noroot" in stated,
      representation: "return=representation" in stated
    }
  end

  # Apple's `Brief: t` predates RFC 7240 and asks for the same thing
  # `return=minimal` does; its clients still send it.
  defp brief?(conn) do
    conn
    |> get_req_header("brief")
    |> Enum.any?(&(String.downcase(String.trim(&1)) == "t"))
  end

  defp minimal?(conn), do: preferences(conn).minimal

  # What `return=minimal` trims: the `404` propstats. The response
  # itself stays — the client asked about the resource, not about the
  # missing properties.
  defp trimmed_missing(responses, false), do: responses

  defp trimmed_missing(responses, true) do
    Enum.map(responses, fn
      {href, propstats} when is_list(propstats) ->
        {href,
         Enum.reject(propstats, fn {status, _properties} -> String.contains?(status, "404") end)}

      response ->
        response
    end)
  end

  defp handler(name, %{reports: reports}) do
    case Map.fetch(reports, name) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, :unsupported_report}
    end
  end

  # A bare 403 says "no". A 403 carrying the precondition that failed
  # says *which* rule was broken, which is the difference between a
  # client retrying differently and a client giving up.
  defp precondition(conn, condition) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error(condition))
  end

  ## --- COPY and MOVE ----------------------------------------------

  defp transfer(kind, conn, options) do
    with :ok <- capable(options, kind),
         {:ok, destination} <- destination(conn),
         {:ok, source} <- resolve(conn, options),
         :ok <- entity_tag_matches(conn, source.path, options),
         :ok <- schedule_tag_matches(conn, source.path, options),
         :ok <- distinct(source, destination),
         :ok <- within_owner(source, destination, options),
         {:ok, replacing?} <- overwritable(conn, destination, options),
         :ok <- parent_of(destination, options),
         :ok <- validate_transfer(kind, source, destination, options),
         :ok <- relocatable(source, destination, options),
         held = transferred_body(source, options),
         displaced = if(replacing?, do: contents(destination, options), else: nil),
         :ok <- carry_out(kind, source, destination, options) do
      aftermath(kind, source, destination, held, displaced, options)
      if kind == :move, do: relocated_hooks(source, destination, options)

      if replacing?,
        do: send_resp(conn, 204, ""),
        else: conn |> at(destination_header(conn)) |> send_resp(201, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :no_destination} -> send_resp(conn, 400, "")
      {:error, :entity_tag} -> send_resp(conn, 412, "")
      {:error, :schedule_tag} -> send_resp(conn, 412, "")
      {:error, :not_found} -> missing_source(conn, kind, options)
      {:error, :same} -> send_resp(conn, 403, "")
      {:error, :foreign} -> send_resp(conn, 403, "")
      {:error, :would_overwrite} -> send_resp(conn, 412, "")
      {:error, :no_parent} -> send_resp(conn, 409, "")
      {:error, :other_server} -> send_resp(conn, 502, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # A resource travels within its owner's tree. Relocating one into
  # somebody else's home — a grant notwithstanding — is how the
  # reference treats it: refused outright, before overwrite or parent
  # checks get a say. The homes are compared by name rather than
  # through links, so a sharee writing through the view in their own
  # home stays in their own home.
  defp within_owner(source, destination, options) do
    if home_owner(source.path, options) == home_owner(destination, options),
      do: :ok,
      else: {:error, :foreign}
  end

  defp home_owner(path, options) do
    for(n <- 1..length(path)//1, do: Enum.take(path, n))
    |> Enum.find_value(fn prefix ->
      case resolved(prefix, options) do
        %Resource{owner: owner} when is_binary(owner) -> owner
        _unowned -> nil
      end
    end)
  end

  # A `MOVE` whose source is gone and whose destination is taken is
  # wrong at both ends, and the reference answers for the destination:
  # it refuses the overwrite before it goes looking for the source.
  defp missing_source(conn, :move, %{store: store, context: context}) do
    with {:ok, destination} <- destination(conn),
         {:ok, _held} <- store.resolve(destination, context) do
      send_resp(conn, 403, "")
    else
      _vacant -> send_resp(conn, 404, "")
    end
  end

  defp missing_source(conn, _kind, _options), do: send_resp(conn, 404, "")

  # RFC 6638 section 3: a scheduling object resource belongs to the
  # calendar of a user who is its organiser or one of its attendees.
  # Relocating one into a calendar somebody else owns — most often
  # into or out of a shared calendar — would hand them an organiser's
  # copy of another person's meeting, which the server would then go
  # on to schedule from on their behalf. A resource carrying no
  # `ORGANIZER` is nobody's meeting and moves freely.
  defp relocatable(source, destination, options) do
    owners = {owner_of(source.path, options), owner_of(destination, options)}

    with {held, target} when held != target <- owners,
         {:ok, body} <- body_of(source, options),
         true <- String.contains?(body, "ORGANIZER") do
      {:error, {Xml.dav(), "need-privileges"}}
    else
      _same_owner_or_unscheduled -> :ok
    end
  end

  # Through any link the store keeps: a calendar shared into someone's
  # home is *owned* by the sharer, however it is addressed.
  defp owner_of(path, options) do
    case path |> Enum.drop(-1) |> located(options) |> resolved(options) do
      %Resource{owner: owner} -> owner
      _absent -> nil
    end
  end

  defp located(path, %{store: store, context: context}) do
    if Store.supports?(store, :origin), do: store.origin(path, context), else: path
  end

  defp resolved(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, resource} -> resource
      _absent -> nil
    end
  end

  # RFC 4791 section 5.3.2 applies its preconditions to "the resource
  # submitted in the PUT request, **or targeted by a COPY or MOVE**".
  # Checking only PUT leaves the back door open: anything invalid can
  # be written to an ordinary collection and then copied in.
  # A collection landing inside a calendar is the same rule as MKCOL,
  # reached by another route. Guarding only MKCOL leaves it open.
  defp validate_transfer(_kind, %Resource{collection?: true}, destination, options),
    do: nestable(destination, options)

  defp validate_transfer(kind, source, destination, options) do
    case body_of(source, options) do
      # A MOVE is the same object relocating, so the source must not
      # count against it: checking a moved event's UID against the copy
      # it is about to stop being refuses every rename.
      {:ok, body} ->
        validate(body, destination, moving(kind, source, options), source.content_type)

      :error ->
        :ok
    end
  end

  defp moving(:move, source, options), do: Map.put(options, :ignoring, source.path)
  defp moving(_copy, _source, options), do: options

  defp body_of(source, %{store: store, context: context}) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(source, context), do: {:ok, IO.iodata_to_binary(data)}
    else
      :error
    end
  end

  # The `Destination` header is a URI, not a path. A destination on
  # another host is 502 rather than a guess: RFC 4918 reserves it for
  # exactly this, and copying across namespaces is not something this
  # server can promise.
  defp destination(conn) do
    case get_req_header(conn, "destination") do
      [value] -> elsewhere(URI.parse(value), conn)
      _absent -> {:error, :no_destination}
    end
  end

  defp elsewhere(%URI{host: host}, %Plug.Conn{host: here})
       when is_binary(host) and host != here do
    {:error, :other_server}
  end

  defp elsewhere(%URI{path: nil}, _conn), do: {:error, :no_destination}

  # A header value is escaped once as a header and once as a URI, so
  # the path arrives with one more layer than a request line carries:
  # `3%2520a.ics` in a `Destination` names the same resource a request
  # for `3%20a.ics` does.
  defp elsewhere(%URI{path: path}, _conn),
    do: {:ok, Enum.map(Store.segments(path), &URI.decode/1)}

  # The new resource's URI, taken from the `Destination` the client
  # sent rather than rebuilt from the parsed path: the client wrote it,
  # it is already a valid URI, and re-encoding it would hand back a
  # different string from the one just requested.
  defp at(conn, nil), do: conn
  defp at(conn, destination), do: put_resp_header(conn, "location", destination)

  defp destination_header(conn), do: conn |> get_req_header("destination") |> List.first()

  defp distinct(%Resource{path: path}, path), do: {:error, :same}
  defp distinct(%Resource{}, _destination), do: :ok

  # `Overwrite` defaults to "T". An "F" against an occupied
  # destination is 412 — the client asked to be stopped.
  defp overwritable(conn, destination, options) do
    occupied? = match?({:ok, _resource}, lookup(destination, options))
    refuses? = get_req_header(conn, "overwrite") == ["F"]

    if occupied? and refuses?, do: {:error, :would_overwrite}, else: {:ok, occupied?}
  end

  # "The server MUST NOT create those intermediate collections
  # automatically" — a missing parent is a conflict, not a hint.
  defp parent_of([], _options), do: :ok

  defp parent_of(destination, options) do
    case lookup(Enum.drop(destination, -1), options) do
      {:ok, _parent} -> :ok
      {:error, :not_found} -> {:error, :no_parent}
    end
  end

  defp lookup([], _options), do: {:ok, :root}
  defp lookup(path, %{store: store, context: context}), do: store.resolve(path, context)

  # RFC 4791 section 5.3.2 applies the PUT rules to "the resource
  # targeted by a COPY or MOVE", and RFC 6638 section 3.1 makes
  # landing in a calendar collection a scheduling operation: an event
  # arriving from a plain collection is being created as a scheduling
  # object and delivers its invitations; one moved between calendars
  # is the same event relocating, so its own content is its previous
  # state and nothing is announced; one moved *out* of the calendar
  # world has been taken off the calendar, which is a delete.
  defp aftermath(_kind, _source, _destination, nil, _displaced, _options), do: :ok

  defp aftermath(kind, source, destination, held, displaced, options) do
    landed = calendar_parent?(Enum.drop(destination, -1), options)
    left = calendar_parent?(Enum.drop(source.path, -1), options)

    if landed do
      previous = if kind == :move and left, do: held, else: displaced
      landed_write(destination, held, previous, options)
    end

    if kind == :move and left and not landed do
      collection = parent(source.path, options)
      withdrawn(source, held, collection, options)
    end

    :ok
  end

  defp relocated_hooks(source, destination, options) do
    options.hooks
    |> Enum.filter(&implements?(&1, :relocated, 3))
    |> Enum.each(& &1.relocated(source.path, destination, options))
  end

  defp landed_write(destination, held, previous, options) do
    case options.store.resolve(destination, options.context) do
      {:ok, resource} -> written(resource, held, previous, destination, false, options)
      _absent -> :ok
    end
  end

  defp transferred_body(source, options) do
    case body_of(source, options) do
      {:ok, body} -> body
      :error -> nil
    end
  end

  defp calendar_parent?(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, resource} -> Cal.calendar?(resource)
      _absent -> false
    end
  end

  defp carry_out(:copy, source, destination, options) do
    options.store.copy(source, destination, options.context)
  end

  defp carry_out(:move, source, destination, options) do
    options.store.move(source, destination, options.context)
  end

  ## --- PROPPATCH --------------------------------------------------

  defp proppatch(conn, options) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- capable(options, :patch),
         {:ok, instructions} <- Xml.parse_proppatch(body),
         {:ok, resource} <- resolve(conn, options) do
      patched(conn, applied(resource, instructions, options))
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :malformed} -> send_resp(conn, 400, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  # RFC 7240: a `PROPPATCH` that succeeded in full has nothing a
  # minimal answer needs to say — a bare `200` says it all.
  defp patched(conn, {_href, propstats} = outcome) do
    succeeded? =
      Enum.all?(propstats, fn {status, _properties} -> String.contains?(status, "200") end)

    if preferences(conn).minimal and succeeded? do
      send_resp(conn, 200, "")
    else
      multistatus(conn, [outcome])
    end
  end

  # PROPPATCH is atomic: *"Instructions MUST either all be executed or
  # none executed."* So a single protected property fails the whole
  # request, and the others report `424 Failed Dependency` — they would
  # have worked, and did not, because of something else.
  defp applied(resource, instructions, options) do
    case Enum.find(instructions, &protected?/1) ||
           refused_by_hook(resource, instructions, options) do
      nil -> attempt(resource, instructions, options)
      blocked -> blocked_by(resource, instructions, blocked)
    end
  end

  # A property an extension gives semantics to is the extension's to
  # refuse — an href set naming collections that must exist, say. The
  # base server cannot judge it, so each instruction is offered to the
  # hooks before anything is stored.
  defp refused_by_hook(resource, instructions, options) do
    judges = Enum.filter(options.hooks, &implements?(&1, :patchable, 3))

    Enum.find(instructions, fn instruction ->
      Enum.any?(judges, &match?({:error, _name}, &1.patchable(resource, instruction, options)))
    end)
  end

  defp attempt(resource, instructions, options) do
    names = for instruction <- instructions, do: name_of(instruction)

    case options.store.patch(resource, instructions, options.context) do
      :ok ->
        {Resource.href(resource), [{"HTTP/1.1 200 OK", for(n <- names, do: {n, nil})}]}

      {:error, :forbidden} ->
        {Resource.href(resource), [{"HTTP/1.1 403 Forbidden", for(n <- names, do: {n, nil})}]}
    end
  end

  defp blocked_by(resource, instructions, blocked) do
    refused = name_of(blocked)

    others =
      for instruction <- instructions,
          name = name_of(instruction),
          name != refused,
          do: {name, nil}

    propstats =
      [
        {"HTTP/1.1 403 Forbidden", [{refused, nil}]},
        {"HTTP/1.1 424 Failed Dependency", others}
      ]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(resource), propstats}
  end

  defp protected?(instruction), do: Properties.protected?(name_of(instruction))

  defp name_of({:set, name, _value}), do: name
  defp name_of({:remove, name}), do: name

  ## --- responses --------------------------------------------------

  defp multistatus(conn, responses) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(@multistatus, Xml.multistatus(responses))
  end

  defp respond(conn, resources, request, options, prefer) do
    responses = Enum.map(resources, &listed_response(&1, request, options))

    multistatus(conn, trimmed_missing(responses, prefer.minimal))
  end

  # A listing names every member, but a member an extension withholds
  # — somebody else's private event — is named with a refusal rather
  # than described. The target itself was already checked before the
  # listing began.
  defp listed_response(resource, request, options) do
    case permitted(resource, options) do
      :ok ->
        response(
          typed(resource, options),
          request,
          advertised(resource, options),
          dead(resource, options),
          options
        )

      {:error, :forbidden} ->
        {Resource.href(resource), {:status, "HTTP/1.1 403 Forbidden"}}
    end
  end

  # `DAV:supported-report-set` answers for the resource it is read on.
  # `DAV:sync-collection` appears only where the store keeps a history
  # to report — advertising it on a collection whose changes cannot be
  # asked for would send a client somewhere the report will refuse it.
  defp advertised(resource, options) do
    reports = Map.keys(options.reports)

    if synchronised?(resource, options),
      do: reports,
      else: List.delete(reports, {Xml.dav(), "sync-collection"})
  end

  defp synchronised?(resource, %{store: store, context: context}) do
    Store.supports?(store, :sync_token) and store.sync_token(resource, context) != nil
  end

  # What a resource *is*, once the extensions have had their say. A
  # store knows it holds a calendar; only the extension that
  # implemented sharing knows that this particular calendar is one
  # shared from somebody else's home.
  defp typed(resource, options) do
    collection = parent(resource.path, options)

    extra =
      options.hooks
      |> Enum.filter(&implements?(&1, :types, 3))
      |> Enum.flat_map(& &1.types(resource, collection, options))

    %{resource | types: Enum.uniq(resource.types ++ extra)}
  end

  # Dead properties are whatever a client stored here, and the server
  # does not interpret them. A store that keeps none is a valid store.
  # Properties that are not live: the ones a store holds, plus the ones
  # an extension computes. `CALDAV:schedule-tag` is the latter — it
  # depends on the object's *content*, which only the extension that
  # understands calendars can read, and computing it here would put
  # knowledge of CalDAV back into the base.
  # Kept apart on purpose. A *stored* value is whatever a client
  # PROPPATCHed, and must never shadow the server's own account of a
  # protected property. A *contributed* one comes from an extension —
  # part of this server — and is exactly the server's own account: it
  # is the only thing that knows what a calendar's free-busy set is.
  # Merging the two would force a choice between letting clients
  # forge protected properties and letting extensions state none.
  defp dead(resource, options) do
    {Map.merge(inherited(resource, options), stored(resource, options)),
     contributed(resource, options)}
  end

  # The floor under the stored properties: what a resource shows when
  # it states nothing of its own. A stored value always wins.
  defp inherited(resource, options) do
    collection = parent(resource.path, options)

    options.hooks
    |> Enum.filter(&implements?(&1, :inherited, 3))
    |> Enum.flat_map(& &1.inherited(resource, collection, options))
    |> Map.new()
  end

  defp stored(resource, %{store: store, context: context}) do
    if Store.supports?(store, :properties) do
      store.properties(resource, context)
    else
      %{}
    end
  end

  # Not filtered by `applies?`. That asks whether a hook cares about
  # writes *into* a collection, which is a different question from
  # whether it has something to say about a resource: CalDAV's
  # `Schedule-Tag` belongs to an object inside a calendar, and Apple's
  # `CS:invite` to the calendar itself. Each hook decides for itself.
  defp contributed(resource, options) do
    collection = parent(resource.path, options)

    current_user(options)
    |> Map.merge(principal_collections(options))
    |> Map.merge(hook_properties(resource, collection, options))
    |> Map.merge(synced(resource, options))
    |> Map.merge(identified(resource, options))
    |> Map.merge(bounded(resource, options))
  end

  # RFC 3744 section 5.8: where the principals live, stated on every
  # resource so a client can find them from anywhere.
  defp principal_collections(%{principals: [_head | _tail] = collections}),
    do: %{{Xml.dav(), "principal-collection-set"} => {:hrefs, collections}}

  defp principal_collections(_options), do: %{}

  # RFC 4331: what a collection may hold and what it holds already.
  # Reported only where the store keeps an account — a tree above the
  # bounded part answers neither property rather than answering
  # infinity.
  defp bounded(collection, %{store: store, context: context}) do
    with true <- Store.supports?(store, :quota),
         {used, available} <- store.quota(collection, context) do
      %{
        {Xml.dav(), "quota-used-bytes"} => Integer.to_string(used),
        {Xml.dav(), "quota-available-bytes"} => Integer.to_string(available)
      }
    else
      _unbounded -> %{}
    end
  end

  # RFC 5842: the identity that names the resource itself, wherever
  # it is bound — only where the store can promise one.
  defp identified(resource, %{store: store, context: context}) do
    case Store.supports?(store, :resource_id) and store.resource_id(resource, context) do
      identity when is_binary(identity) ->
        %{{Xml.dav(), "resource-id"} => {:hrefs, [identity]}}

      _unidentified ->
        %{}
    end
  end

  # RFC 6578: a synchronised collection reports the token a client
  # would hold after seeing the collection as it stands now.
  defp synced(resource, %{store: store, context: context}) do
    case Store.supports?(store, :sync_token) and store.sync_token(resource, context) do
      token when is_binary(token) -> %{{Xml.dav(), "sync-token"} => token}
      _not_synchronised -> %{}
    end
  end

  # "Who am I", answered from the authenticated principal rather than
  # from the resource. RFC 5397 exists so a client can find its own
  # principal URL without being told it out of band, and a server that
  # answers with the resource's owner tells every caller they own
  # whatever they are looking at.
  defp current_user(%{principal: nil}),
    do: %{
      {Xml.dav(), "current-user-principal"} => {:elements, [Xml.dav()], "<D:unauthenticated/>"}
    }

  defp current_user(%{principal: principal}),
    do: %{{Xml.dav(), "current-user-principal"} => {:hrefs, [principal]}}

  # `function_exported?/3` answers for *loaded* modules only, and a
  # request served before anything else touched an extension would
  # silently skip its callbacks. Loading is idempotent and cheap.
  defp implements?(hook, name, arity) do
    Code.ensure_loaded?(hook) and function_exported?(hook, name, arity)
  end

  defp hook_properties(resource, collection, options) do
    options.hooks
    |> Enum.filter(&implements?(&1, :properties, 3))
    |> Enum.flat_map(& &1.properties(resource, collection, options))
    |> Map.new()
  end

  defp response(%Resource{} = resource, :allprop, reports, dead, _options) do
    everything = Properties.all(resource) ++ [report_set(reports)] ++ listed(dead)

    {Resource.href(resource), [{"HTTP/1.1 200 OK", everything}]}
  end

  # `propname` asks what exists, not what it is worth, so every value
  # is empty by design rather than by omission.
  defp response(%Resource{} = resource, :propname, reports, dead, _options) do
    names =
      for {qname, _value} <- Properties.all(resource) ++ [report_set(reports)] ++ listed(dead),
          do: {qname, nil}

    {Resource.href(resource), [{"HTTP/1.1 200 OK", names}]}
  end

  # A request routinely asks for properties that partly exist, which is
  # why one response carries a propstat per status rather than one
  # status per response.
  defp response(%Resource{} = resource, {:prop, names}, reports, dead, options) do
    {found, missing} =
      Enum.reduce(names, {[], []}, fn qname, {found, missing} ->
        case fetch(resource, qname, reports, dead, options) do
          {:ok, value} -> {found ++ [{qname, value}], missing}
          :error -> {found, missing ++ [{qname, nil}]}
        end
      end)

    propstats =
      [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(resource), propstats}
  end

  defp fetch(_resource, {"DAV:", "supported-report-set"}, reports, _dead, _options) do
    {_qname, value} = report_set(reports)
    {:ok, value}
  end

  # Live first: a client cannot shadow the server's own account of a
  # resource by storing a dead property with the same name.
  # A stored value wins over a computed one for any property a client
  # is allowed to set: the whole point of setting `displayname` is that
  # it replaces the default the server would otherwise derive from the
  # path. Protected properties are the other way round — nothing a
  # client stored may shadow the server's own answer.
  defp fetch(resource, qname, _reports, {stored, contributed}, options) do
    case Map.fetch(contributed, qname) do
      {:ok, value} -> {:ok, value}
      :error -> from_store(resource, qname, stored, options)
    end
  end

  defp from_store(resource, qname, stored, options) do
    case Map.fetch(stored, qname) do
      {:ok, value} ->
        if Properties.protected?(qname), do: live(resource, qname, options), else: {:ok, value}

      :error ->
        live(resource, qname, options)
    end
  end

  # A protected name in the dead store is an implementation's own
  # record — the access list an `ACL` stored, say — and never a value
  # `allprop` may hand out raw.
  defp listed({stored, contributed}) do
    stored
    |> Map.reject(fn {qname, _value} -> Properties.protected?(qname) end)
    |> Map.merge(contributed)
    |> Map.to_list()
  end

  # RFC 3744 section 5.5: reading `DAV:acl` takes the `read-acl`
  # privilege, which belongs to the owner and the administrators — a
  # proxy sees the calendars, not who else may.
  defp live(resource, {"DAV:", "acl"} = qname, options) do
    if acl_readable?(resource, options),
      do: Properties.fetch(resource, qname),
      else: :error
  end

  # `DAV:owner` names the person the resource belongs to. A principal
  # is nobody's property, so it states none (the reference does the
  # same); an object inside a calendar belongs to whoever the calendar
  # does, whether or not the store said so on the object itself.
  defp live(resource, {"DAV:", "owner"} = qname, options) do
    cond do
      Acl.principal?(resource) ->
        :error

      match?({:ok, _value}, Properties.fetch(resource, qname)) ->
        Properties.fetch(resource, qname)

      true ->
        inherited_owner(resource, options)
    end
  end

  defp live(resource, qname, _options), do: Properties.fetch(resource, qname)

  defp inherited_owner(%Resource{path: [_head | _tail] = path}, options) do
    %{store: store, context: context} = options

    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, %Resource{owner: owner}} when is_binary(owner) -> {:ok, {:hrefs, [owner]}}
      {:ok, parent} -> inherited_owner(parent, options)
      _missing -> :error
    end
  end

  defp inherited_owner(_resource, _options), do: :error

  defp acl_readable?(%Resource{owner: owner}, options) when is_binary(owner) do
    caller = Map.get(options, :principal)

    is_binary(caller) and
      (canonical_principal_of(caller, options) == owner or administrator?(caller, options))
  end

  # An unowned resource's list is the deployment's policy, and only
  # the administrators read policy. A deployment with no
  # authentication has every caller as the owner, so `nil` reads.
  defp acl_readable?(%Resource{}, options) do
    case Map.get(options, :principal) do
      nil -> true
      caller -> administrator?(caller, options)
    end
  end

  defp administrator?(caller, options) do
    Enum.any?(Map.get(options, :administrators, []), fn admin ->
      canonical_principal_of(admin, options) == canonical_principal_of(caller, options)
    end)
  end

  defp canonical_principal_of(href, %{store: store, context: context}) do
    case store.resolve(Store.segments(href), context) do
      {:ok, %Resource{owner: owner}} when is_binary(owner) -> owner
      _unknown -> href
    end
  end

  defp report_set(reports) do
    {{Xml.dav(), "supported-report-set"}, Xml.supported_report_set(reports)}
  end
end
