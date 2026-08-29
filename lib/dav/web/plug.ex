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

  @allow "OPTIONS, HEAD, GET, PROPFIND"
  @multistatus 207

  @impl Plug
  def init(options) do
    %{
      store: Keyword.fetch!(options, :store),
      context: Keyword.get(options, :context)
    }
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, %{} = options) do
    dispatch(conn.method, conn, options)
  end

  defp dispatch("OPTIONS", conn, _options) do
    conn
    |> put_resp_header("dav", "1")
    |> put_resp_header("allow", @allow)
    |> put_resp_header("ms-author-via", "DAV")
    |> send_resp(200, "")
  end

  defp dispatch("PROPFIND", conn, options), do: propfind(conn, options)

  defp dispatch(_method, conn, _options) do
    conn
    |> put_resp_header("allow", @allow)
    |> send_resp(405, "")
  end

  ## --- PROPFIND ---------------------------------------------------

  defp propfind(conn, options) do
    {:ok, body, conn} = read_body(conn)

    with {:ok, request} <- Xml.parse_propfind(body),
         {:ok, depth} <- depth(conn),
         {:ok, resource} <- resolve(conn, options),
         {:ok, resources} <- gather(resource, depth, options) do
      respond(conn, resources, request)
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

  defp respond(conn, resources, request) do
    body =
      resources
      |> Enum.map(&response(&1, request))
      |> Xml.multistatus()

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(@multistatus, body)
  end

  defp response(%Resource{} = resource, :allprop) do
    {Resource.href(resource), [{"HTTP/1.1 200 OK", Properties.all(resource)}]}
  end

  # `propname` asks what exists, not what it is worth, so every value
  # is empty by design rather than by omission.
  defp response(%Resource{} = resource, :propname) do
    names = for {qname, _value} <- Properties.all(resource), do: {qname, nil}

    {Resource.href(resource), [{"HTTP/1.1 200 OK", names}]}
  end

  # A request routinely asks for properties that partly exist, which is
  # why one response carries a propstat per status rather than one
  # status per response.
  defp response(%Resource{} = resource, {:prop, names}) do
    {found, missing} =
      Enum.reduce(names, {[], []}, fn qname, {found, missing} ->
        case Properties.fetch(resource, qname) do
          {:ok, value} -> {found ++ [{qname, value}], missing}
          :error -> {found, missing ++ [{qname, nil}]}
        end
      end)

    propstats =
      [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(resource), propstats}
  end
end
