defmodule Dav.Cal.Delegation do
  @moduledoc """
  Apple's calendar-user-proxy extension — acting on somebody's behalf.

  Every principal has two child principals, `calendar-proxy-read` and
  `calendar-proxy-write`, standing for "may read my calendars" and
  "may write them". A user grants either by `PROPPATCH`ing the child's
  `DAV:group-member-set`; from then on the members appear in each
  other's `DAV:group-membership`, the delegators in the members'
  `CS:calendar-proxy-read-for` and `CS:calendar-proxy-write-for`, and
  the access follows.

  No RFC defines this — it is the draft Apple shipped, and the most
  widely deployed way one assistant manages another person's calendar.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.Schedule
  alias Dav.Cal.Sharing
  alias Dav.Web.Acl
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @calendarserver "http://calendarserver.org/ns/"

  @doc """
  Delegation applies to no collection's writes.

  ### Arguments

  * `collection` is the collection being written into, unused.

  ### Returns

  * `false` — the properties below are contributed regardless.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: false
  def applies?(_collection), do: false

  @doc """
  Delegation has nothing to do when a resource is written.

  ### Arguments

  * `change` is the write, unused.

  * `options` are the plug options, unused.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  The delegation properties of a principal.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is its parent, unused here.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `DAV:group-membership` and the `CS:calendar-proxy-read-for` /
    `CS:calendar-proxy-write-for` pair for a principal, and `[]` for
    everything else.

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(resource, _collection, options) do
    cond do
      not Acl.principal?(resource) -> []
      proxy_principal?(resource) -> group_properties(resource)
      true -> principal_properties(resource, options)
    end
  end

  # The record type Apple's directory reports for a proxy group.
  defp group_properties(%Resource{path: path}) do
    kind =
      case List.last(path) do
        "calendar-proxy-read" -> "read-delegate-group"
        "calendar-proxy-write" -> "write-delegate-group"
      end

    [{{@calendarserver, "record-type"}, kind}]
  end

  defp principal_properties(resource, options) do
    held = memberships_of(resource, options)

    [
      {{Xml.dav(), "group-membership"}, {:hrefs, Enum.map(held, &group_href/1)}},
      {{@calendarserver, "calendar-proxy-read-for"},
       {:hrefs, for({owner, "calendar-proxy-read"} <- held, do: owner)}},
      {{@calendarserver, "calendar-proxy-write-for"},
       {:hrefs, for({owner, "calendar-proxy-write"} <- held, do: owner)}}
    ]
  end

  defp group_href({owner, leaf}), do: owner <> leaf <> "/"

  # Every proxy group that names this principal, as `{delegator, leaf}`
  # pairs — deduplicated across the spellings a principal may be
  # addressed by, since a grant lands wherever the client wrote it.
  defp memberships_of(%Resource{} = resource, options) do
    mine = identity_of(resource)

    for proxy <- proxy_principals(options),
        is_binary(proxy.owner),
        member <- stored_members(proxy, options),
        identified(member, options) == mine,
        uniq: true,
        do: {proxy.owner, List.last(proxy.path)}
  end

  defp identity_of(%Resource{owner: owner}) when is_binary(owner), do: owner
  defp identity_of(%Resource{} = resource), do: Resource.href(resource)

  defp identified(href, %{store: store, context: context}) do
    case store.resolve(Store.segments(href), context) do
      {:ok, %Resource{} = found} -> identity_of(found)
      _unknown -> href
    end
  end

  defp stored_members(proxy, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(proxy, context),
         {:hrefs, members} <- Map.get(properties, {Xml.dav(), "group-member-set"}) do
      members
    else
      _nothing_granted -> []
    end
  end

  @doc """
  Whether one user is the other's proxy.

  ### Arguments

  * `principal` is the candidate proxy's principal URL.

  * `owner` is the delegator's canonical principal URL.

  * `access` is `:read` for either grant, `:write` for the write
    grant alone.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `true` when a proxy group of the owner names the principal.

  """
  @spec proxy_of?(String.t(), String.t(), :read | :write, map()) :: boolean()
  def proxy_of?(principal, owner, access, options) when is_binary(principal) do
    wanted =
      case access do
        :write -> ["calendar-proxy-write"]
        :read -> ["calendar-proxy-read", "calendar-proxy-write"]
      end

    mine = identified(principal, options)

    Enum.any?(proxy_principals(options), fn proxy ->
      proxy.owner == owner and List.last(proxy.path) in wanted and
        Enum.any?(stored_members(proxy, options), &(identified(&1, options) == mine))
    end)
  end

  def proxy_of?(_principal, _owner, _access, _options), do: false

  # Every proxy principal the deployment holds, walked from the
  # principal tree's root. Grants may be stored on any spelling of a
  # principal, so every spelling is visited.
  defp proxy_principals(%{store: store, context: context}) do
    case store.resolve(["principals"], context) do
      {:ok, root} -> walk(root, 4, %{store: store, context: context})
      _no_principals -> []
    end
  end

  defp walk(_resource, 0, _options), do: []

  defp walk(resource, depth, %{store: store, context: context} = options) do
    case store.children(resource, context) do
      {:ok, children} -> Enum.flat_map(children, &collected(&1, depth, options))
      _nothing -> []
    end
  end

  defp collected(child, depth, options) do
    if proxy_principal?(child), do: [child], else: walk(child, depth - 1, options)
  end

  defp proxy_principal?(%Resource{path: path}) do
    List.last(path) in ["calendar-proxy-read", "calendar-proxy-write"]
  end

  @doc """
  Whether a `PROPPATCH` instruction on a proxy group is acceptable.

  ### Arguments

  * `resource` is the resource being patched.

  * `instruction` is one `{:set, name, value}` or `{:remove, name}`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, or `{:error, qname}` naming the refused property — a
    member that is not a known principal, or a group the directory
    provides and locks.

  """
  @impl Dav.Web.Hook
  @spec patchable(Resource.t(), {:set, Xml.qname(), term()} | {:remove, Xml.qname()}, map()) ::
          :ok | {:error, Xml.qname()}
  def patchable(resource, {:set, {"DAV:", "group-member-set"} = name, value}, options) do
    cond do
      not proxy_principal?(resource) -> :ok
      locked?(resource, options) -> {:error, name}
      not members_known?(value, options) -> {:error, name}
      true -> :ok
    end
  end

  def patchable(resource, {:remove, {"DAV:", "group-member-set"} = name}, options) do
    if proxy_principal?(resource) and locked?(resource, options),
      do: {:error, name},
      else: :ok
  end

  def patchable(_resource, _instruction, _options), do: :ok

  # A directory-provided group — a room's, a location's — is the
  # directory's to state, not a client's to edit.
  defp locked?(%Resource{owner: owner}, %{store: store, context: context})
       when is_binary(owner) do
    with true <- Store.supports?(store, :addresses),
         {:ok, addresses} <- store.addresses(owner, context),
         true <- Store.supports?(store, :unattended?) do
      Enum.any?(addresses, &store.unattended?(&1, context))
    else
      _not_a_directory_group -> false
    end
  end

  defp locked?(_resource, _options), do: false

  @doc """
  Whether the caller may read a resource in somebody's calendar home.

  ### Arguments

  * `resource` is the resolved resource.

  * `options` carries `:store`, `:context`, `:principal` and
    `:administrators`.

  ### Returns

  * `:ok`, or `{:error, :forbidden}` when the resource sits in a
    calendar home whose owner the caller is not, has no proxy grant
    from, and holds no share of.

  """
  @impl Dav.Web.Hook
  @spec readable(Resource.t(), map()) :: :ok | {:error, :forbidden}
  def readable(%Resource{path: path} = resource, options) do
    if "dropbox" in path do
      # The attachment area has its own reader rules — attendees of
      # the events the files belong to — and they are not these.
      :ok
    else
      case home_owner(resource, options) do
        nil -> :ok
        owner -> allowed_reader(owner, resource, options)
      end
    end
  end

  defp allowed_reader(owner, resource, options) do
    caller = Map.get(options, :principal)
    owner = identified(owner, options)

    cond do
      # A deployment that lets callers stay anonymous has chosen not
      # to tell them apart; only an *identified* stranger is refused.
      is_nil(caller) -> :ok
      identified(caller, options) == owner -> :ok
      administrator?(caller, options) -> :ok
      proxy_of?(caller, owner, :read, options) -> :ok
      shared_to_caller?(resource, options) -> :ok
      true -> {:error, :forbidden}
    end
  end

  @doc """
  Whether the caller may store a resource at this path.

  ### Arguments

  * `path` is where the client is writing.

  * `kind` is what it is writing, unused — data is data.

  * `options` carries `:store`, `:context`, `:principal` and
    `:administrators`.

  ### Returns

  * `:ok`, or `{:error, :forbidden}` — writing into somebody's home
    takes the write grant, where reading takes either.

  """
  @impl Dav.Web.Hook
  @spec creatable(path :: [String.t()], atom(), map()) :: :ok | {:error, :forbidden}
  def creatable(path, _kind, %{store: store, context: context} = options) do
    with false <- "dropbox" in path,
         caller when is_binary(caller) <- Map.get(options, :principal),
         %Resource{} = parent <- nearest(path, store, context),
         owner when is_binary(owner) <- home_owner(parent, options),
         false <- authorized_writer?(caller, owner, options) do
      {:error, :forbidden}
    else
      _permitted -> :ok
    end
  end

  @doc """
  Whether the caller may write on the owner's behalf.

  ### Arguments

  * `caller` is the calling principal URL, or `nil` for nobody.

  * `owner` is the canonical principal URL whose things are written.

  * `options` carries `:store`, `:context` and `:administrators`.

  ### Returns

  * `true` for the owner themselves, an administrator, or a holder of
    the owner's write-proxy grant.

  """
  @spec authorized_writer?(String.t() | nil, String.t(), map()) :: boolean()
  def authorized_writer?(caller, owner, options) when is_binary(caller) and is_binary(owner) do
    owner = identified(owner, options)

    identified(caller, options) == owner or administrator?(caller, options) or
      proxy_of?(caller, owner, :write, options)
  end

  def authorized_writer?(_caller, _owner, _options), do: false

  defp nearest([], _store, _context), do: nil

  defp nearest(path, store, context) do
    case store.resolve(path, context) do
      {:ok, %Resource{} = found} -> found
      _absent -> nearest(Enum.drop(path, -1), store, context)
    end
  end

  defp administrator?(caller, options) do
    named = identified(caller, options)

    options
    |> Map.get(:administrators, [])
    |> Enum.any?(&(is_binary(&1) and identified(&1, options) == named))
  end

  # The owner whose home this is — the nearest owned ancestor that
  # actually holds calendars. A principal is owned too, but reading
  # somebody's principal is discovery, not their diary.
  defp home_owner(%Resource{} = resource, %{store: store, context: context} = options) do
    Enum.find_value(lineage(resource.path), fn ancestors ->
      with {:ok, %Resource{owner: owner} = held} when is_binary(owner) <-
             store.resolve(ancestors, context),
           true <- calendar_home?(held, options) do
        owner
      else
        _not_the_home -> nil
      end
    end)
  end

  defp lineage(path) do
    for depth <- length(path)..1//-1, do: Enum.take(path, depth)
  end

  defp calendar_home?(%Resource{collection?: true} = home, %{store: store, context: context}) do
    case store.children(home, context) do
      {:ok, children} ->
        Enum.any?(children, fn child ->
          Cal.calendar?(child) or Schedule.inbox?(child)
        end)

      _nothing ->
        false
    end
  end

  defp calendar_home?(_resource, _options), do: false

  # A sharee reads the calendar shared to them wherever they meet it.
  defp shared_to_caller?(%Resource{} = resource, %{store: store, context: context} = options) do
    Enum.any?(lineage(resource.path), fn ancestors ->
      case store.resolve(ancestors, context) do
        {:ok, %Resource{} = held} ->
          Cal.calendar?(held) and Sharing.granted_on(held, options) != nil

        _absent ->
          false
      end
    end)
  end

  # A member is named by its canonical principal URL — the stable
  # spelling `identity_of/1` reports. Any other spelling, resolvable
  # or not, is refused the way the reference refuses a name it cannot
  # place.
  defp members_known?({:hrefs, members}, %{store: store, context: context}) do
    Enum.all?(members, fn href ->
      case store.resolve(Store.segments(href), context) do
        {:ok, %Resource{} = found} ->
          Acl.principal?(found) and
            Store.segments(identity_of(found)) == Store.segments(href)

        _unknown ->
          false
      end
    end)
  end

  defp members_known?(_value, _options), do: true
end
