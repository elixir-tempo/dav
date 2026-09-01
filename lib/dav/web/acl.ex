defmodule Dav.Web.Acl do
  @moduledoc """
  Access control — RFC 3744.

  Who may do what to a resource, and how a client finds that out
  before trying. The specification is large; what a calendar server
  actually needs of it is small and well defined:

  * a **principal** is a resource that identifies a person or group,
    reported by `DAV:resourcetype` like any other type;

  * **privileges** form a tree, with `DAV:all` containing `DAV:read`
    and `DAV:write`, and those containing finer ones;

  * `DAV:current-user-privilege-set` tells a client what it may do
    *here*, which is what lets a calendar grey out a read-only
    collection rather than letting the user edit it and fail;

  * `DAV:acl` is the full list of who may do what.

  ### This server grants, it does not yet deny

  There is no authentication layer, so every request is the resource's
  owner and `DAV:current-user-privilege-set` reports the full set.
  That is stated rather than hidden: a client is told it may write
  because, on this server, it may. Adding authentication later changes
  what these properties report without changing what reports them.

  """

  alias Dav.Web.Resource
  alias Dav.Xml

  # The privilege tree of RFC 3744 section 3. `DAV:all` is the root and
  # aggregates everything; the leaves are what an ACE actually grants.
  # `CALDAV:read-free-busy` is RFC 4791 section 6.1: contained in
  # `DAV:read`, and the one privilege the suite reads back after an
  # `ACL` grant of `DAV:read`.
  @tree {"all",
         [
           {"read",
            [
              {"read-acl", []},
              {"read-current-user-privilege-set", []},
              {{:caldav, "read-free-busy"}, []}
            ]},
           {"write",
            [{"write-properties", []}, {"write-content", []}, {"bind", []}, {"unbind", []}]},
           {"write-acl", []},
           {"unlock", []}
         ]}

  @read_tree {"read",
              [
                {"read-acl", []},
                {"read-current-user-privilege-set", []},
                {{:caldav, "read-free-busy"}, []}
              ]}

  @doc """
  The resource type of a principal.

  ### Returns

  * The `DAV:principal` qualified name.

  ### Examples

      iex> Dav.Web.Acl.principal()
      {"DAV:", "principal"}

  """
  @spec principal() :: Xml.qname()
  def principal, do: {Xml.dav(), "principal"}

  @doc """
  Whether a resource is a principal.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports `DAV:principal`.

  ### Examples

      iex> Dav.Web.Acl.principal?(%Dav.Web.Resource{collection?: true, types: [Dav.Web.Acl.principal()]})
      true

      iex> Dav.Web.Acl.principal?(%Dav.Web.Resource{collection?: true})
      false

  """
  @spec principal?(Resource.t()) :: boolean()
  def principal?(%Resource{types: types}), do: principal() in types

  @doc """
  The privileges this server understands, as a nested value.

  `DAV:supported-privilege-set` is how a client learns the vocabulary
  before it tries to use it in an ACL — without it, a client can only
  guess which privilege names mean anything here.

  ### Returns

  * A `t:Dav.Xml.value/0` holding the privilege tree.

  ### Examples

      iex> {:elements, namespaces, _inner} = Dav.Web.Acl.supported_privilege_set()
      iex> namespaces
      ["DAV:", "urn:ietf:params:xml:ns:caldav"]

  """
  @spec supported_privilege_set() :: Xml.value()
  def supported_privilege_set, do: {:elements, [Xml.dav(), Xml.caldav()], supported(@tree)}

  defp supported({name, children}) do
    [
      "<D:supported-privilege>",
      privilege(name),
      "<D:description>",
      described(name),
      "</D:description>",
      Enum.map(children, &supported/1),
      "</D:supported-privilege>"
    ]
  end

  defp described({:caldav, name}), do: name
  defp described(name), do: name

  @doc """
  What the current user may do here.

  ### Returns

  * A `t:Dav.Xml.value/0` listing each granted privilege.

  ### Examples

      iex> {:elements, _namespaces, inner} = Dav.Web.Acl.current_user_privilege_set()
      iex> IO.iodata_to_binary(inner) =~ "<D:privilege><D:read/></D:privilege>"
      true

  """
  @spec current_user_privilege_set() :: Xml.value()
  def current_user_privilege_set, do: current_user_privilege_set([])

  @doc """
  The full privilege set with extras a context adds.

  ### Arguments

  * `additional` lists extra privileges — a bare name for `DAV:`, or
    `{:caldav, name}` — a scheduling Inbox adds `CALDAV:schedule`.

  ### Returns

  * A `t:Dav.Xml.value/0`.

  ### Examples

      iex> {:elements, _namespaces, inner} = Dav.Web.Acl.current_user_privilege_set([{:caldav, "schedule"}])
      iex> IO.iodata_to_binary(inner) =~ "<C:schedule/>"
      true

  """
  @spec current_user_privilege_set([String.t() | {:caldav, String.t()}]) :: Xml.value()
  def current_user_privilege_set(additional) do
    {:elements, [Xml.dav(), Xml.caldav()], Enum.map(granted() ++ additional, &privilege/1)}
  end

  @doc """
  The privilege set of somewhere readable but not writable.

  The `DAV:read` subtree alone — what `DAV:current-user-privilege-set`
  reports on a server-owned area like the attachment store, where even
  the owner may look but not touch.

  ### Returns

  * A `t:Dav.Xml.value/0`.

  ### Examples

      iex> {:elements, _namespaces, inner} = Dav.Web.Acl.read_privilege_set()
      iex> IO.iodata_to_binary(inner) =~ "<D:write/>"
      false

  """
  @spec read_privilege_set() :: Xml.value()
  def read_privilege_set do
    {:elements, [Xml.dav(), Xml.caldav()], Enum.map(flatten(@read_tree), &privilege/1)}
  end

  @doc """
  The access control list of a resource.

  One ACE granting everything to the resource's owner, which is what
  this server's single-user model amounts to. The shape is the one a
  client expects, so replacing the policy later does not change the
  document.

  ### Arguments

  * `owner` is the owner's principal URL.

  ### Returns

  * A `t:Dav.Xml.value/0` holding the ACL.

  ### Examples

      iex> {:elements, _namespaces, inner} = Dav.Web.Acl.acl("/principals/users/kip/")
      iex> IO.iodata_to_binary(inner) =~ "<D:href>/principals/users/kip/</D:href>"
      true

  """
  @spec acl(String.t()) :: Xml.value()
  def acl(owner) do
    inner = [
      "<D:ace>",
      "<D:principal><D:href>",
      owner,
      "</D:href></D:principal>",
      "<D:grant>",
      Enum.map(granted(), &privilege/1),
      "</D:grant>",
      "</D:ace>"
    ]

    {:elements, [Xml.dav(), Xml.caldav()], inner}
  end

  @doc """
  The restrictions this server places on an ACL it is asked to set.

  ### Returns

  * A `t:Dav.Xml.value/0`.

  ### Examples

      iex> {:elements, _namespaces, inner} = Dav.Web.Acl.acl_restrictions()
      iex> IO.iodata_to_binary(inner) =~ "no-invert"
      true

  """
  @spec acl_restrictions() :: Xml.value()
  def acl_restrictions, do: {:elements, [Xml.dav()], ["<D:no-invert/>"]}

  # Every privilege in the tree, flattened. With no authentication
  # there is nothing to withhold.
  defp granted, do: flatten(@tree)

  defp flatten({name, children}), do: [name | Enum.flat_map(children, &flatten/1)]

  defp privilege({:caldav, name}), do: ["<D:privilege><C:", name, "/></D:privilege>"]
  defp privilege(name), do: ["<D:privilege><D:", name, "/></D:privilege>"]
end
