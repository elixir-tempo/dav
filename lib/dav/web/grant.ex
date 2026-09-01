defmodule Dav.Web.Grant do
  @moduledoc """
  The `ACL` method — RFC 3744 section 8.1.

  A client sends a `DAV:acl` naming principals and the privileges each
  is granted or denied; the server stores the list in order, and the
  read and write enforcement honours it from then on — the first ace
  matching a principal and privilege decides. A principal is named by
  `DAV:href` or is `DAV:authenticated` (anyone logged in); the
  privileges are `DAV:read` and `DAV:write` plus the read-side leaves
  a grant of them implies. Anything else — an abstract principal the
  server cannot place, a privilege it does not enforce — is refused
  rather than stored and quietly ignored: a client must not believe a
  restriction took hold when it did not.

  Only the resource's owner or an administrator may change its access
  list, and a calendar home does not take one at all — the home's
  access is the deployment's policy, answered `405` as the reference
  answers it.

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
         :ok <- settable_target(resource, options),
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
  The access list stored on a resource, in ace order.

  ### Arguments

  * `resource` is the resource whose list is read.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A list of `{kind, principal, privileges}` entries — `kind` is
    `:grant` or `:deny`, `principal` is `{:href, url}` or
    `:authenticated`, `privileges` are the privilege names as sent.
    Empty when no list was ever stored.

  """
  @spec entries(Resource.t(), map()) :: [
          {:grant | :deny, {:href, String.t()} | :authenticated, [String.t()]}
        ]
  def entries(%Resource{} = resource, %{store: store, context: context}) do
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

  # A calendar home takes no access list of its own — its access is
  # the deployment's policy, and the reference answers `405` there. A
  # home is the owned collection sitting directly under an unowned
  # container.
  defp settable_target(
         %Resource{owner: owner, collection?: true, path: [_head | _tail] = path},
         %{store: store, context: context}
       )
       when is_binary(owner) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, %Resource{owner: parent_owner}} when is_binary(parent_owner) -> :ok
      _unowned_container -> {:error, :unsupported}
    end
  end

  defp settable_target(%Resource{}, _options), do: :ok

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

  @supported_privileges ~w(read write read-acl read-current-user-privilege-set read-free-busy)

  defp one(ace) do
    principal = ace.children |> Enum.find(&named?(&1, "principal"))
    side = Enum.find(ace.children, &(named?(&1, "grant") or named?(&1, "deny")))

    with %{name: {_namespace, kind}} <- side,
         {:ok, who} <- principal_of(principal),
         {:ok, privileges} <- privileges_of(side) do
      {:ok, {String.to_existing_atom(kind), who, privileges}}
    else
      nil -> {:error, {Xml.dav(), "recognized-principal"}}
      refusal -> refusal
    end
  end

  defp principal_of(nil), do: {:error, {Xml.dav(), "recognized-principal"}}

  defp principal_of(principal) do
    href = Enum.find(principal.children, &named?(&1, "href"))

    cond do
      is_map(href) -> {:ok, {:href, String.trim(href.text)}}
      Enum.any?(principal.children, &named?(&1, "authenticated")) -> {:ok, :authenticated}
      true -> {:error, {Xml.dav(), "recognized-principal"}}
    end
  end

  defp privileges_of(side) do
    named =
      for privilege <- side.children,
          named?(privilege, "privilege"),
          %{name: {_namespace, local}} <- privilege.children,
          do: local

    if Enum.all?(named, &(&1 in @supported_privileges)),
      do: {:ok, named},
      else: {:error, {Xml.dav(), "not-supported-privilege"}}
  end

  # One line per ace, in ace order — plain text a later read takes
  # apart without another grammar. `@authenticated` stands for the
  # abstract principal; an href never starts with `@`.
  defp stored(aces) do
    Enum.map_join(aces, "\n", fn {kind, who, privileges} ->
      Enum.join([Atom.to_string(kind), spelled(who), Enum.join(privileges, ",")], " ")
    end)
  end

  defp spelled(:authenticated), do: "@authenticated"
  defp spelled({:href, href}), do: href

  defp decoded(stored) do
    entries =
      for line <- String.split(stored, "\n", trim: true),
          [kind, who, privileges] <- [String.split(line, " ", parts: 3)],
          kind in ~w(grant deny),
          do: {String.to_existing_atom(kind), addressed(who), String.split(privileges, ",")}

    {:ok, entries}
  end

  defp addressed("@authenticated"), do: :authenticated
  defp addressed(href), do: {:href, href}

  defp forbidden(conn, {namespace, local}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error({namespace, local}))
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
