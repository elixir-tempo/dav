defmodule Dav.Web.Grant do
  @moduledoc """
  The `ACL` method — RFC 3744 section 8.1, the grant-only core.

  A client sends a `DAV:acl` naming principals and the privileges each
  is granted; the server stores them, and the read and write
  enforcement honours them from then on. What is implemented is what
  clients actually send when they share by access list: `DAV:grant`
  aces naming a principal by `DAV:href` with `DAV:read` and
  `DAV:write` privileges. A `DAV:deny` ace, an abstract principal, or
  a privilege outside that pair is refused rather than stored and
  quietly ignored — a client must not believe a restriction took hold
  when it did not.

  Only the resource's owner or an administrator may change its access
  list.

  """

  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal.Delegation
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @doc """
  Handle an `ACL` request.

  ### Arguments

  * `conn` is the request, with its body still unread.

  * `path` is the request path in segments.

  * `options` carries `:store`, `:context`, `:principal` and
    `:administrators`.

  ### Returns

  * The `t:Plug.Conn.t/0`, with a response sent.

  """
  @impl Dav.Web.Method
  @spec call(Plug.Conn.t(), [String.t()], map()) :: Plug.Conn.t()
  def call(conn, path, %{store: store, context: context} = options) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- supported(store),
         {:ok, resource} <- resolve(path, options),
         :ok <- settable_by_caller(resource, options),
         {:ok, aces} <- parsed(body),
         :ok <- store.patch(resource, [{:set, {Xml.dav(), "acl"}, stored(aces)}], context) do
      send_resp(conn, 200, "")
    else
      {:error, :unsupported} -> send_resp(conn, 405, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :forbidden} -> forbidden(conn, {Xml.dav(), "need-privileges"})
      {:error, {_namespace, _local} = failed} -> forbidden(conn, failed)
      {:error, :malformed} -> send_resp(conn, 400, "")
    end
  end

  @doc """
  The access list stored on a resource, as `{principal, privileges}`.

  ### Arguments

  * `resource` is the resource whose list is read.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A list of `{href, [:read | :write]}` pairs, empty when no list
    was ever stored.

  """
  @spec granted(Resource.t(), map()) :: [{String.t(), [:read | :write]}]
  def granted(%Resource{} = resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context),
         stored when is_binary(stored) <- Map.get(properties, {Xml.dav(), "acl"}),
         {:ok, aces} <- decoded(stored) do
      aces
    else
      _nothing_stored -> []
    end
  end

  defp supported(store) do
    if Store.supports?(store, :patch), do: :ok, else: {:error, :unsupported}
  end

  defp resolve(path, %{store: store, context: context}) do
    store.resolve(path, context)
  end

  # RFC 3744 section 8.1: changing the list takes `DAV:write-acl`,
  # which belongs to the owner — and to the deployment's
  # administrators, who hold everything.
  defp settable_by_caller(%Resource{owner: owner}, options)
       when is_binary(owner) do
    caller = Map.get(options, :principal)

    cond do
      is_nil(caller) -> :ok
      Delegation.authorized_writer?(caller, owner, options) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp settable_by_caller(%Resource{}, _options), do: :ok

  defp parsed(body) do
    with {:ok, document} <- Xml.parse(body),
         {_namespace, "acl"} <- document.name do
      aces(document)
    else
      _not_an_acl -> {:error, :malformed}
    end
  end

  defp aces(document) do
    document.children
    |> Enum.filter(&named?(&1, "ace"))
    |> Enum.reduce_while({:ok, []}, fn ace, {:ok, held} ->
      case one(ace) do
        {:ok, entry} -> {:cont, {:ok, held ++ [entry]}}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp one(ace) do
    principal = ace.children |> Enum.find(&named?(&1, "principal"))
    grant = ace.children |> Enum.find(&named?(&1, "grant"))
    deny = ace.children |> Enum.find(&named?(&1, "deny"))

    with false <- deny != nil,
         %{} <- grant,
         href when is_binary(href) <- href_of(principal),
         {:ok, privileges} <- privileges_of(grant) do
      {:ok, {href, privileges}}
    else
      true -> {:error, {Xml.dav(), "grant-only"}}
      _unusable -> {:error, {Xml.dav(), "recognized-principal"}}
    end
  end

  defp href_of(nil), do: nil

  defp href_of(principal) do
    case Enum.find(principal.children, &named?(&1, "href")) do
      nil -> nil
      element -> String.trim(element.text)
    end
  end

  defp privileges_of(grant) do
    named =
      for privilege <- grant.children,
          named?(privilege, "privilege"),
          %{name: {_namespace, local}} <- privilege.children,
          do: local

    if Enum.all?(named, &(&1 in ["read", "write"])),
      do: {:ok, Enum.map(named, &String.to_existing_atom/1)},
      else: {:error, {Xml.dav(), "not-supported-privilege"}}
  end

  # One line per ace, privilege names joined — plain text a later read
  # takes apart without another grammar.
  defp stored(aces) do
    Enum.map_join(aces, "\n", fn {href, privileges} ->
      href <> " " <> Enum.map_join(privileges, ",", &Atom.to_string/1)
    end)
  end

  defp decoded(stored) do
    entries =
      for line <- String.split(stored, "\n", trim: true),
          [href, privileges] <- [String.split(line, " ", parts: 2)],
          do:
            {href,
             for(
               p <- String.split(privileges, ","),
               p in ~w(read write),
               do: String.to_existing_atom(p)
             )}

    {:ok, entries}
  end

  defp forbidden(conn, {namespace, local}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error({namespace, local}))
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
