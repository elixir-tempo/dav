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
      methods: Map.new(Keyword.get(options, :methods, []))
    }
  end

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
    if authenticated?(options), do: dispatch(conn.method, conn, options), else: challenge(conn)
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
    |> put_resp_header("dav", "1")
    |> put_resp_header("allow", allowed(options))
    |> put_resp_header("ms-author-via", "DAV")
    |> send_resp(200, "")
  end

  defp dispatch(method, conn, options) when method in ["GET", "POST"] do
    case acted(conn, options) do
      {:ok, conn} -> conn
      :unhandled -> undirected(method, conn, options)
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
         :ok <- readable(resource),
         {:ok, body} <- options.store.read(resource, options.context) do
      conn
      |> etag(resource)
      |> contributed_headers(resource, options)
      |> put_resp_content_type(resource.content_type || "application/octet-stream")
      |> send_resp(200, if(method == "HEAD", do: "", else: body))
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :not_found} -> send_resp(conn, 404, "")
      # RFC 4918 leaves GET on a collection to the server. Refusing is
      # honest; inventing a directory listing is a different product.
      {:error, :is_collection} -> send_resp(conn, 405, "")
    end
  end

  defp put(conn, options) do
    {:ok, body, conn} = read_body(conn)
    type = conn |> get_req_header("content-type") |> List.first()
    path = Store.segments(conn.request_path)

    with :ok <- capable(options, :put),
         :ok <- writable(path, options),
         :ok <- schedule_tag_matches(conn, path, options),
         :ok <- validate(body, path, options, type),
         previous = contents(path, options),
         {:ok, outcome, resource} <- options.store.put(path, body, type, options.context) do
      written(resource, body, previous, path, options)

      conn
      |> etag(resource)
      |> contributed_headers(resource, options)
      |> send_resp(if(outcome == :created, do: 201, else: 204), "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :schedule_tag} -> send_resp(conn, 412, "")
      # A missing parent is a conflict, not an invitation to create it.
      {:error, :conflict} -> send_resp(conn, 409, "")
      {:error, :collection} -> send_resp(conn, 403, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
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

  defp removed(resource, body, options) do
    collection = parent(resource.path, options)
    change = %{resource: resource, body: body, previous: body, collection: collection}

    for hook <- options.hooks,
        hook.applies?(collection),
        function_exported?(hook, :deleted, 2),
        do: hook.deleted(change, options)

    :ok
  end

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

  defp current_schedule_tag(path, options) do
    with {:ok, resource} <- options.store.resolve(path, options.context),
         collection = parent(resource.path, options),
         {_name, value} <-
           options.hooks
           |> Enum.filter(&function_exported?(&1, :headers, 3))
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
      |> Enum.filter(&function_exported?(&1, :action, 4))
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
    |> Enum.filter(&function_exported?(&1, :headers, 3))
    |> Enum.flat_map(& &1.headers(resource, collection, options))
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end

  # What a collection *does* when written to is its business too:
  # storing an event with attendees has to deliver the invitations
  # (RFC 6638 section 3), and a hook cannot fail the write that
  # triggered it.
  defp written(resource, body, previous, path, options) do
    collection = parent(path, options)
    change = %{resource: resource, body: body, previous: previous, collection: collection}

    for hook <- options.hooks, hook.applies?(collection), do: hook.written(change, options)

    :ok
  end

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
         :ok <- schedule_tag_matches(conn, resource.path, options),
         # Read before removing: afterwards there is nothing left to
         # read, and a hook that must know what the resource held has
         # no way to find out.
         held = contents(resource, options) || "",
         :ok <- options.store.delete(resource, options.context) do
      removed(resource, held, options)
      send_resp(conn, 204, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :schedule_tag} -> send_resp(conn, 412, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  defp mkcol(conn, options) do
    {:ok, body, conn} = read_body(conn)

    path = Store.segments(conn.request_path)

    with :ok <- capable(options, :mkcol),
         :ok <- no_body(body),
         :ok <- nestable(path, options),
         {:ok, _resource} <- options.store.mkcol(path, options.context) do
      send_resp(conn, 201, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      # RFC 4918 reserves a body for extended MKCOL, which this is not.
      {:error, :body} -> send_resp(conn, 415, "")
      {:error, :exists} -> send_resp(conn, 405, "")
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

  defp readable(%Resource{collection?: true}), do: {:error, :is_collection}
  defp readable(%Resource{}), do: :ok

  defp no_body(""), do: :ok
  defp no_body(_body), do: {:error, :body}

  defp etag(conn, %Resource{etag: nil}), do: conn
  defp etag(conn, %Resource{etag: etag}), do: put_resp_header(conn, "etag", etag)

  ## --- PROPFIND ---------------------------------------------------

  defp propfind(conn, options) do
    {:ok, body, conn} = read_body(conn)

    with {:ok, request} <- Xml.parse_propfind(body),
         {:ok, depth} <- finite(depth(conn, {:ok, :infinity})),
         {:ok, resource} <- resolve(conn, options),
         {:ok, resources} <- gather(resource, depth, options) do
      respond(conn, resources, request, options)
    else
      {:error, :malformed} -> send_resp(conn, 400, "")
      {:error, :bad_depth} -> send_resp(conn, 400, "")
      {:error, :depth_infinity} -> precondition(conn, {Xml.dav(), "propfind-finite-depth"})
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

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

  defp gather(%Resource{} = collection, _depth, %{store: store, context: context}) do
    {:ok, children} = store.children(collection, context)
    {:ok, [collection | children]}
  end

  ## --- REPORT -----------------------------------------------------

  defp report(conn, options) do
    {:ok, body, conn} = read_body(conn)

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

  defp answer(conn, responses) when is_list(responses), do: multistatus(conn, responses)

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
         :ok <- distinct(source, destination),
         {:ok, replacing?} <- overwritable(conn, destination, options),
         :ok <- parent_of(destination, options),
         :ok <- validate_transfer(kind, source, destination, options),
         :ok <- carry_out(kind, source, destination, options) do
      if replacing?,
        do: send_resp(conn, 204, ""),
        else: conn |> at(destination_header(conn)) |> send_resp(201, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :no_destination} -> send_resp(conn, 400, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :same} -> send_resp(conn, 403, "")
      {:error, :would_overwrite} -> send_resp(conn, 412, "")
      {:error, :no_parent} -> send_resp(conn, 409, "")
      {:error, :other_server} -> send_resp(conn, 502, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
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
  defp elsewhere(%URI{path: path}, _conn), do: {:ok, Store.segments(path)}

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
      multistatus(conn, [applied(resource, instructions, options)])
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :malformed} -> send_resp(conn, 400, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  # PROPPATCH is atomic: *"Instructions MUST either all be executed or
  # none executed."* So a single protected property fails the whole
  # request, and the others report `424 Failed Dependency` — they would
  # have worked, and did not, because of something else.
  defp applied(resource, instructions, options) do
    case Enum.find(instructions, &protected?/1) do
      nil -> attempt(resource, instructions, options)
      blocked -> blocked_by(resource, instructions, blocked)
    end
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

  defp respond(conn, resources, request, options) do
    reports = Map.keys(options.reports)

    multistatus(
      conn,
      Enum.map(resources, &response(&1, request, reports, dead(&1, options)))
    )
  end

  # Dead properties are whatever a client stored here, and the server
  # does not interpret them. A store that keeps none is a valid store.
  # Properties that are not live: the ones a store holds, plus the ones
  # an extension computes. `CALDAV:schedule-tag` is the latter — it
  # depends on the object's *content*, which only the extension that
  # understands calendars can read, and computing it here would put
  # knowledge of CalDAV back into the base.
  defp dead(resource, options) do
    stored(resource, options) |> Map.merge(contributed(resource, options))
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

    Map.merge(current_user(options), hook_properties(resource, collection, options))
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

  defp hook_properties(resource, collection, options) do
    options.hooks
    |> Enum.filter(&function_exported?(&1, :properties, 3))
    |> Enum.flat_map(& &1.properties(resource, collection, options))
    |> Map.new()
  end

  defp response(%Resource{} = resource, :allprop, reports, dead) do
    everything = Properties.all(resource) ++ [report_set(reports)] ++ Map.to_list(dead)

    {Resource.href(resource), [{"HTTP/1.1 200 OK", everything}]}
  end

  # `propname` asks what exists, not what it is worth, so every value
  # is empty by design rather than by omission.
  defp response(%Resource{} = resource, :propname, reports, dead) do
    names =
      for {qname, _value} <-
            Properties.all(resource) ++ [report_set(reports)] ++ Map.to_list(dead),
          do: {qname, nil}

    {Resource.href(resource), [{"HTTP/1.1 200 OK", names}]}
  end

  # A request routinely asks for properties that partly exist, which is
  # why one response carries a propstat per status rather than one
  # status per response.
  defp response(%Resource{} = resource, {:prop, names}, reports, dead) do
    {found, missing} =
      Enum.reduce(names, {[], []}, fn qname, {found, missing} ->
        case fetch(resource, qname, reports, dead) do
          {:ok, value} -> {found ++ [{qname, value}], missing}
          :error -> {found, missing ++ [{qname, nil}]}
        end
      end)

    propstats =
      [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(resource), propstats}
  end

  defp fetch(_resource, {"DAV:", "supported-report-set"}, reports, _dead) do
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
  defp fetch(resource, qname, _reports, dead) do
    case Map.fetch(dead, qname) do
      {:ok, value} ->
        if Properties.protected?(qname), do: live(resource, qname), else: {:ok, value}

      :error ->
        live(resource, qname)
    end
  end

  defp live(resource, qname), do: Properties.fetch(resource, qname)

  defp report_set(reports) do
    {{Xml.dav(), "supported-report-set"}, Xml.supported_report_set(reports)}
  end
end
