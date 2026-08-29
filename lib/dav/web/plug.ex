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

  @impl Plug
  def init(options) do
    %{
      store: Keyword.fetch!(options, :store),
      context: Keyword.get(options, :context),
      reports: Map.new(Keyword.get(options, :reports, []))
    }
  end

  # The `Allow` header is built from what the store can actually do.
  # A read-only store gets a read-only server, and never advertises a
  # method that would fail — which matters more than it sounds, because
  # a client that believes `PUT` works behaves differently from one
  # that knows it does not.
  defp allowed(%{store: store}) do
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

    Enum.join(["OPTIONS", "PROPFIND", "REPORT"] ++ read ++ optional, ", ")
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, %{} = options) do
    dispatch(conn.method, conn, options)
  end

  defp dispatch("OPTIONS", conn, options) do
    conn
    |> put_resp_header("dav", "1")
    |> put_resp_header("allow", allowed(options))
    |> put_resp_header("ms-author-via", "DAV")
    |> send_resp(200, "")
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

  defp dispatch(_method, conn, options), do: refuse(conn, options)

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

    with :ok <- capable(options, :put),
         {:ok, outcome, resource} <-
           options.store.put(Store.segments(conn.request_path), body, type, options.context) do
      conn
      |> etag(resource)
      |> send_resp(if(outcome == :created, do: 201, else: 204), "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      # A missing parent is a conflict, not an invitation to create it.
      {:error, :conflict} -> send_resp(conn, 409, "")
    end
  end

  defp delete(conn, options) do
    with :ok <- capable(options, :delete),
         {:ok, resource} <- resolve(conn, options),
         :ok <- options.store.delete(resource, options.context) do
      send_resp(conn, 204, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  defp mkcol(conn, options) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- capable(options, :mkcol),
         :ok <- no_body(body),
         {:ok, _resource} <-
           options.store.mkcol(Store.segments(conn.request_path), options.context) do
      send_resp(conn, 201, "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      # RFC 4918 reserves a body for extended MKCOL, which this is not.
      {:error, :body} -> send_resp(conn, 415, "")
      {:error, :exists} -> send_resp(conn, 405, "")
      {:error, :conflict} -> send_resp(conn, 409, "")
    end
  end

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
         {:ok, depth} <- depth(conn),
         {:ok, resource} <- resolve(conn, options),
         {:ok, resources} <- gather(resource, depth, options) do
      respond(conn, resources, request, options)
    else
      {:error, :malformed} -> send_resp(conn, 400, "")
      {:error, :bad_depth} -> send_resp(conn, 400, "")
      {:error, :depth_infinity} -> send_resp(conn, 403, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  # `Depth: infinity` is refused rather than served. RFC 4918 allows a
  # server to refuse it, and answering it over an unbounded tree is a
  # denial of service with a specification behind it.
  defp depth(conn) do
    case get_req_header(conn, "depth") do
      [] -> {:ok, 1}
      ["0"] -> {:ok, 0}
      ["1"] -> {:ok, 1}
      ["infinity"] -> {:error, :depth_infinity}
      _other -> {:error, :bad_depth}
    end
  end

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
         {:ok, depth} <- depth(conn),
         {:ok, resource} <- resolve(conn, options),
         {:ok, handler} <- handler(name, options),
         {:ok, responses} <- handler.run(resource, body, depth, options.context) do
      multistatus(conn, responses)
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
    end
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
         :ok <- distinct(source, destination),
         {:ok, replacing?} <- overwritable(conn, destination, options),
         :ok <- parent_of(destination, options),
         :ok <- carry_out(kind, source, destination, options) do
      send_resp(conn, if(replacing?, do: 204, else: 201), "")
    else
      {:error, :unsupported} -> refuse(conn, options)
      {:error, :no_destination} -> send_resp(conn, 400, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :same} -> send_resp(conn, 403, "")
      {:error, :would_overwrite} -> send_resp(conn, 412, "")
      {:error, :no_parent} -> send_resp(conn, 409, "")
      {:error, :other_server} -> send_resp(conn, 502, "")
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
  defp dead(resource, %{store: store, context: context}) do
    if Store.supports?(store, :properties) do
      store.properties(resource, context)
    else
      %{}
    end
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
  defp fetch(resource, qname, _reports, dead) do
    case Properties.fetch(resource, qname) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(dead, qname)
    end
  end

  defp report_set(reports) do
    {{Xml.dav(), "supported-report-set"}, Xml.supported_report_set(reports)}
  end
end
