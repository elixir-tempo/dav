defmodule Dav.Cal.Sharing do
  @moduledoc """
  Calendar sharing — Apple's `calendarserver.org` extension.

  Letting one person see or edit another's calendar, which every
  CalDAV client on Apple's platforms expects and which no RFC defines.
  It is a vendor extension, and it is the one most widely deployed:
  ignoring it means a server that Apple Calendar can talk to but not
  share with.

  ### How a share is made

  The owner `POST`s a `CS:share` document at their calendar, naming
  who to invite and what access to grant:

      <CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
        <CS:set>
          <D:href>mailto:bob@example.com</D:href>
          <CS:summary>My Shared Calendar</CS:summary>
          <CS:read-write/>
        </CS:set>
      </CS:share>

  The server records the invitation on the calendar — reported by the
  `CS:invite` property — and drops a **notification** into the
  invitee's notification collection. The invitee replies by `POST`ing
  a `CS:invite-reply`, and on acceptance the server answers with the
  URL the shared calendar now has in *their* home.

  ### Why the notification matters

  There is nowhere else for the invitation to go. An invitee has no
  reason to poll a calendar they cannot yet see, so a share that is
  recorded only on the owner's side is a share nobody hears about.

  """

  @behaviour Dav.Web.Hook
  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @namespace "http://calendarserver.org/ns/"

  # `DAV:all` is not among them. A sharee may read and write the
  # calendar's contents; administering it — its access control, its
  # very existence — stays with the person who shared it, and a client
  # told it holds every privilege discovers otherwise by having a
  # request refused.
  @shared_write ~w(read write write-properties write-content bind unbind)

  @doc """
  The `calendarserver.org` namespace.

  ### Returns

  * The namespace URI.

  ### Examples

      iex> Dav.Cal.Sharing.namespace()
      "http://calendarserver.org/ns/"

  """
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The resource type of a notification collection.

  ### Returns

  * The `CS:notification` qualified name.

  ### Examples

      iex> Dav.Cal.Sharing.notification()
      {"http://calendarserver.org/ns/", "notification"}

  """
  @spec notification() :: Xml.qname()
  def notification, do: {@namespace, "notification"}

  @doc """
  The resource type a shared calendar reports alongside `calendar`.

  ### Returns

  * The `CS:shared-owner` qualified name.

  ### Examples

      iex> Dav.Cal.Sharing.shared_owner()
      {"http://calendarserver.org/ns/", "shared-owner"}

  """
  @spec shared_owner() :: Xml.qname()
  def shared_owner, do: {@namespace, "shared-owner"}

  @doc """
  The resource type of a calendar shared into this home from another.

  ### Returns

  * The `CS:shared` qualified name.

  ### Examples

      iex> Dav.Cal.Sharing.shared()
      {"http://calendarserver.org/ns/", "shared"}

  """
  @spec shared() :: Xml.qname()
  def shared, do: {@namespace, "shared"}

  @doc """
  Whether the sharing properties apply — only to a calendar.

  ### Arguments

  * `collection` is the resource being described.

  ### Returns

  * `true` for a calendar collection.

  ### Examples

      iex> Dav.Cal.Sharing.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  Sharing has nothing to do when a calendar object is written.

  ### Arguments

  * `change` is the write, ignored.

  * `options` is ignored.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  Withdraw a deleted calendar's outstanding invitations.

  ### Arguments

  * `change` is the deletion, whose `:resource` is what was removed.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec deleted(Hook.change(), map()) :: :ok
  def deleted(%{resource: %Resource{} = resource} = change, options) do
    cond do
      # A sharee deleting their view has left the share, not killed
      # the calendar. The slot they occupied stays spoken for — the
      # reference keeps the share record, and creating an ordinary
      # calendar over a retired share slot is refused.
      view_deleted?(change) ->
        left_share(change, options)
        retire(resource, options)

      # An invitation to a calendar that is gone is worse than no
      # invitation: the sharee's client offers it, and accepting it
      # fails with nothing to say why. The invitations come from the
      # change rather than the store — by now the calendar, and the
      # property they lived on, are gone.
      Cal.calendar?(resource) ->
        for invitation <- recorded_on(change), do: withdraw(resource, invitation.href, options)
        :ok

      true ->
        :ok
    end
  end

  def deleted(_change, _options), do: :ok

  # The view is a real collection of the sharee's; what marks it is
  # the `shared-url` it keeps. Read from the change — by now the
  # collection, and the property with it, are gone.
  defp view_deleted?(change) do
    change
    |> Map.get(:properties, %{})
    |> Map.has_key?({@namespace, "shared-url"})
  end

  # The sharer's record hears about the departure: the invitation
  # stands at "deleted", so a later re-share asks afresh instead of
  # claiming an acceptance that no longer holds.
  defp left_share(change, %{store: store, context: context} = options) do
    with {:hrefs, [shared | _rest]} <-
           change |> Map.get(:properties, %{}) |> Map.get({@namespace, "shared-url"}),
         {:ok, original} <- store.resolve(Store.segments(shared), context),
         who when is_binary(who) <- Map.get(options, :principal),
         [address | _more] <- addresses_of(who, options) do
      answered(original, address, "deleted", options)
    end

    :ok
  end

  defp retire(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :patch),
         {:ok, home} <- store.resolve(Enum.drop(resource.path, -1), context) do
      held = retired_paths(home, %{store: store, context: context})
      value = Enum.map_join([resource.path | held], "\n", &Enum.join(&1, "/"))
      store.patch(home, [{:set, {@namespace, "retired-shares"}, value}], context)
    end

    :ok
  end

  defp retired_paths(home, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(home, context),
         value when is_binary(value) <- Map.get(properties, {@namespace, "retired-shares"}) do
      for line <- String.split(value, "\n", trim: true), do: String.split(line, "/", trim: true)
    else
      _none -> []
    end
  end

  @doc """
  Whether a path is a retired share slot.

  A sharee who deleted their view of a shared calendar has left the
  share; the path it occupied stays reserved, and an ordinary
  calendar may not be created over it.

  ### Arguments

  * `path` is the path being created.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `true` when a share view was deleted at this path, and `false`
    otherwise.

  """
  @spec retired?([String.t()], map()) :: boolean()
  def retired?(path, %{store: store, context: context} = options) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, home} -> path in retired_paths(home, options)
      _no_home -> false
    end
  end

  defp recorded_on(change) do
    case change |> Map.get(:properties, %{}) |> Map.get(invite_property()) do
      value when is_binary(value) -> decode(value)
      _unshared -> []
    end
  end

  @doc """
  The sharing properties of a calendar.

  `CS:invite` lists who has been invited and what they were granted —
  it is how an owner's client shows the sharing panel — and
  `CS:allowed-sharing-modes` says whether the calendar may be shared
  at all.

  ### Arguments

  * `resource` is the calendar.

  * `collection` is its parent, unused.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The sharing properties.

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(resource, _collection, options) do
    if Cal.calendar?(resource) do
      [
        {{@namespace, "invite"}, invite(resource, options)},
        {{@namespace, "allowed-sharing-modes"},
         {:elements, [@namespace], ~s(<CS:can-be-shared xmlns:CS=") <> @namespace <> ~s("/>)}}
      ] ++ borrowed(resource, options) ++ privileges(resource, options)
    else
      []
    end
  end

  # A shared calendar sits in the invitee's home but is not theirs:
  # `DAV:owner` names the person who shared it, and reporting the
  # invitee tells every client that each sharee owns their own copy.
  # The link already records where the original lives, so the owner is
  # read from there rather than stored twice and left to disagree.
  @doc """
  The sharing resource types of a calendar.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is its parent, unused here.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `[CS:shared]` for a calendar shared into this home from another,
    `[CS:shared-owner]` for one the owner has shared out, and `[]` for
    a calendar that is neither.

  """
  @impl Dav.Web.Hook
  @spec types(Resource.t(), Resource.t() | nil, map()) :: [Xml.qname()]
  def types(resource, _collection, options) do
    cond do
      not Cal.calendar?(resource) -> []
      linked?(resource, options) -> [shared()]
      shared_out?(resource, options) -> [shared_owner()]
      true -> []
    end
  end

  defp linked?(resource, options) do
    case stored_properties(resource, options) do
      %{} = properties -> Map.has_key?(properties, {@namespace, "shared-url"})
      _none -> false
    end
  end

  defp shared_out?(resource, %{store: store, context: context}) do
    current(resource, store, context) != []
  end

  defp borrowed(resource, %{store: store, context: context} = options) do
    with %{} = properties <- stored_properties(resource, options),
         {:hrefs, [shared | _rest]} <- Map.get(properties, {@namespace, "shared-url"}),
         {:ok, %Resource{owner: owner}} when is_binary(owner) <-
           store.resolve(Store.segments(shared), context) do
      [{{"DAV:", "owner"}, {:hrefs, [owner]}}]
    else
      _not_a_link -> []
    end
  end

  @doc """
  Whether the caller may write to a collection.

  ### Arguments

  * `collection` is the collection being written into, or `nil`.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `false` only for someone whose invitation to a shared calendar
    grants read access. Everybody else — the owner, a read-write
    sharee, anyone writing to a calendar of their own — may write.

  ### Examples

      iex> Dav.Cal.Sharing.writable?(nil, %{})
      true

  """
  @spec writable?(Resource.t() | nil, map()) :: boolean()
  def writable?(nil, _options), do: true

  def writable?(collection, options), do: granted_to(collection, options) != "read"

  # What the caller may actually do here. A calendar shared read-only
  # is still a calendar the invitee can see, and a client told it has
  # every privilege discovers otherwise by having its writes refused —
  # which is exactly what `DAV:current-user-privilege-set` exists to
  # prevent.
  defp privileges(resource, options) do
    case granted_to(resource, options) do
      nil -> []
      "read" -> [{{"DAV:", "current-user-privilege-set"}, granted(~w(read read-acl))}]
      _read_write -> [{{"DAV:", "current-user-privilege-set"}, granted(@shared_write)}]
    end
  end

  defp granted(names) do
    {:elements, [Xml.dav()],
     Enum.map(names ++ ["read-current-user-privilege-set"], fn name ->
       ["<D:privilege><D:", name, "/></D:privilege>"]
     end)}
  end

  # The access this caller was invited with, or `nil` when they are
  # not a sharee — the owner, or somebody looking at their own
  # calendar, is bound by nothing recorded here.
  defp granted_to(resource, options) do
    case linked_original(resource, options) do
      %Resource{} = original -> granted_on(original, options)
      _owner_or_unshared -> nil
    end
  end

  @doc """
  The access this caller holds on a shared calendar's original.

  ### Arguments

  * `original` is the calendar as its owner holds it — not a sharee's
    view of it.

  * `options` are the plug options, carrying the store, its context
    and the calling principal.

  ### Returns

  * `"read"` or `"read-write"` when the caller was invited to the
    calendar, or holds proxy access to its owner.

  * `nil` when the caller is nobody the sharing records name — the
    owner included.

  """
  @spec granted_on(Resource.t(), map()) :: String.t() | nil
  def granted_on(%Resource{} = original, options) do
    case Map.get(options, :principal) do
      who when is_binary(who) ->
        named = [who | addresses_of(who, options)]

        case Enum.find(effective(original, options), &(&1.href in named)) do
          nil -> proxied(original, named, options)
          invitation -> invitation.access
        end

      _anonymous ->
        nil
    end
  end

  # Access without an invitation. Someone made a proxy of another
  # user's calendars was given their access directly, so the grant is
  # recorded on the owner's proxy principals rather than on the
  # calendar — and a calendar bound into a proxy's own home has no
  # invitation to read it from.
  defp proxied(original, named, options) do
    cond do
      member?(original.owner, "calendar-proxy-write", named, options) -> "read-write"
      member?(original.owner, "calendar-proxy-read", named, options) -> "read"
      true -> nil
    end
  end

  defp member?(nil, _proxy, _named, _options), do: false

  defp member?(owner, proxy, named, %{store: store, context: context} = options) do
    with {:ok, principal} <- store.resolve(Store.segments(owner) ++ [proxy], context),
         %{} = properties <- stored_properties(principal, options),
         {:hrefs, members} <- Map.get(properties, {"DAV:", "group-member-set"}) do
      Enum.any?(members, &(&1 in named))
    else
      _no_such_proxy -> false
    end
  end

  # An invitation names its invitee however the sharer addressed
  # them — a `mailto:`, a principal URL — and the caller arrives as a
  # principal. Both spellings have to be tried, or a sharee looks like
  # a stranger to the calendar they were given.
  defp addresses_of(who, %{store: store, context: context}) do
    with true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(who, context) do
      addresses
    else
      _unknown -> []
    end
  end

  defp linked_original(resource, %{store: store, context: context} = options) do
    with %{} = properties <- stored_properties(resource, options),
         {:hrefs, [shared | _rest]} <- Map.get(properties, {@namespace, "shared-url"}),
         {:ok, original} <- store.resolve(Store.segments(shared), context) do
      original
    else
      _not_a_link -> nil
    end
  end

  defp stored_properties(resource, %{store: store, context: context}) do
    if Store.supports?(store, :properties), do: store.properties(resource, context)
  end

  defp invite(calendar, options) do
    # On a sharee's view the property answers from the origin — who
    # shares this calendar, and with whom — with the sharer named as
    # the organizer, the way the sharee's client expects to find them.
    {source, organizer} =
      case linked_original(calendar, options) do
        nil -> {calendar, []}
        original -> {original, organizer_element(original, options)}
      end

    inner =
      for invitation <- effective(source, options) do
        [
          # The prefixes are declared here rather than assumed. A
          # property value is markup inside somebody else's document,
          # and which prefix that document bound to this namespace is
          # not ours to know.
          ~s(<CS:user xmlns:CS=") <> @namespace <> ~s(" xmlns:D="DAV:">),
          "<D:href>",
          escape(canonical(invitation.href, options)),
          "</D:href>",
          common_name(invitation.href, options),
          "<CS:access><CS:",
          invitation.access,
          "/></CS:access>",
          "<CS:invite-",
          Map.get(invitation, :state) || "noresponse",
          "/>",
          "</CS:user>"
        ]
      end

    {:elements, [@namespace, Xml.dav()], [organizer | inner]}
  end

  defp organizer_element(original, options) do
    [
      ~s(<CS:organizer xmlns:CS=") <> @namespace <> ~s(" xmlns:D="DAV:">),
      "<D:href>",
      escape(original.owner || ""),
      "</D:href>",
      named(original.owner, options),
      "</CS:organizer>"
    ]
  end

  @doc """
  The properties a shared view inherits from its origin.

  A calendar shared into somebody's home shows the sharer's stored
  properties — description, display name, colour — until the sharee
  stores their own on the view; those always win. The share's own
  bookkeeping does not travel.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is its parent, unused.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The origin's stored properties for a shared view, and nothing
    for any other resource.

  """
  @impl Dav.Web.Hook
  @spec inherited(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def inherited(resource, _collection, options) do
    with %Resource{} = original <- linked_original(resource, options),
         %{} = properties <- stored_properties(original, options) do
      # A direct share is the owner's calendar seen whole — colour
      # and all. An invited share starts from per-user defaults: the
      # view is named and coloured by the sharee, and only the
      # calendar's own description shows through.
      invited? = invited_view?(original, options)

      for {name, value} <- properties,
          not private_to_origin?(name),
          not (invited? and per_user?(name)),
          do: {name, value}
    else
      _not_a_view -> []
    end
  end

  defp invited_view?(original, %{store: store, context: context} = options) do
    case Map.get(options, :principal) do
      who when is_binary(who) ->
        named = for address <- [who | addresses_of(who, options)], do: canonical(address, options)

        Enum.any?(
          current(original, store, context),
          &(canonical(&1.href, options) in named)
        )

      _anonymous ->
        false
    end
  end

  defp private_to_origin?({@namespace, local})
       when local in ~w(invite-state retired-shares shared-url),
       do: true

  defp private_to_origin?({_namespace, _local}), do: false

  # The display name and colour are per-user by design: the view is
  # named at accept time from the invitation's summary, and each side
  # paints their own copy without the other noticing.
  defp per_user?({"DAV:", "displayname"}), do: true
  defp per_user?({"http://apple.com/ns/ical/", "calendar-color"}), do: true

  # A default alarm is the holder's reminder, not the calendar's
  # property: a sharee starts with none and sets their own without
  # putting an alarm on the sharer's copy of anything.
  defp per_user?({"urn:ietf:params:xml:ns:caldav", "default-alarm-" <> _kind}), do: true
  defp per_user?({_namespace, _local}), do: false

  @impl Dav.Web.Method
  def call(conn, path, options) do
    with {:ok, resource} <- resolve(path, options),
         {:ok, body, conn} <- request_body(conn, options),
         {:ok, document} <- Xml.parse(body) do
      dispatch(conn, document, resource, options)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      _unreadable -> send_resp(conn, 400, "")
    end
  end

  defp dispatch(conn, %{name: {@namespace, "share"}} = document, resource, options) do
    if Cal.calendar?(resource) do
      share(conn, document, resource, options)
    else
      send_resp(conn, 403, "")
    end
  end

  defp dispatch(conn, %{name: {@namespace, "invite-reply"}} = document, resource, options) do
    reply(conn, document, resource, options)
  end

  # Not a sharing document. Another `POST` handler may want it, and
  # saying so is more useful than refusing on its behalf.
  defp dispatch(conn, _document, _resource, _options), do: send_resp(conn, 400, "")

  ## --- inviting ---------------------------------------------------

  defp share(conn, document, calendar, options) do
    invitations =
      for element <- children(document, "set"),
          invitation <- membered(invitation(element), options),
          do: invitation

    # Removing a group removes the shares it gave, and only those: a
    # member invited in their own right keeps that invitation, and a
    # member who is in the group twice over — through a subgroup —
    # keeps the one the other group gave them.
    removals =
      for element <- children(document, "remove"),
          href <- withdrawn_by(href_of(element), calendar, options),
          do: href

    # One person, one invitation: somebody reached through two groups,
    # or through a group and directly, is invited once, at the access
    # the sharer meant them to have.
    invitations = merged(invitations, options)

    case Enum.filter(invitations, &refused?(&1, options)) do
      [] ->
        existing = current(calendar, options.store, options.context)

        # A re-invitation changes the terms, not the answer: somebody
        # who accepted stays accepted at the new access, and the
        # notification says so rather than asking them afresh.
        invitations = Enum.map(invitations, &carried_state(&1, existing, options))

        record(calendar, invitations, removals, options)
        for invitation <- invitations, do: notify(calendar, invitation, options)
        for href <- removals, do: uninvite(calendar, href, existing, options)

        send_resp(conn, 200, "")

      refused ->
        withheld(conn, invitations, refused)
    end
  end

  # A share named directly outranks one that arrived through a group,
  # and between two group shares the wider access wins — being in a
  # read-write group is not undone by also being in a read-only one.
  defp merged(invitations, options) do
    invitations
    |> Enum.group_by(&canonical(&1.href, options))
    |> Enum.map(fn {_who, [first | rest]} -> Enum.reduce(rest, first, &stronger/2) end)
  end

  defp stronger(invitation, held) do
    cond do
      is_nil(invitation.group) and not is_nil(held.group) -> invitation
      not is_nil(invitation.group) and is_nil(held.group) -> held
      invitation.access == "read-write" -> invitation
      true -> held
    end
  end

  defp withdrawn_by(href, calendar, options) do
    case group_members(href, options) do
      [] ->
        [href]

      members ->
        wanted = canonical(href, options)
        held = current(calendar, options.store, options.context)

        for %{href: theirs, group: group} <- held,
            is_binary(group),
            canonical(group, options) == wanted,
            canonical(theirs, options) in Enum.map(members, &canonical(&1, options)),
            do: theirs
    end
  end

  defp carried_state(invitation, existing, options) do
    wanted = canonical(invitation.href, options)

    case Enum.find(existing, &(canonical(&1.href, options) == wanted)) do
      # Somebody who answered keeps their answer; somebody who left —
      # or never answered — is being asked afresh.
      %{state: state} when state in ~w(accepted declined) ->
        Map.put(invitation, :state, state)

      _fresh_or_departed ->
        invitation
    end
  end

  # An invitation is worth recording only if it can reach somebody. An
  # address the server cannot resolve names nobody — a typo, most
  # often — and a sharer inviting themselves would be granted access
  # they already have and then see their own calendar twice.
  defp refused?(%{href: href}, options) do
    not (is_binary(href) and href != "") or mine?(href, options) or
      not resolvable?(href, options)
  end

  defp mine?(href, options) do
    case Map.get(options, :principal) do
      who when is_binary(who) -> href == who or href in addresses_of(who, options)
      _anonymous -> false
    end
  end

  defp resolvable?(href, %{store: store, context: context}) do
    Store.supports?(store, :principal) and match?({:ok, _who}, store.principal(href, context))
  end

  # RFC 4918 section 11.2: where one member of a request fails, the
  # others are reported `424 Failed Dependency` rather than quietly
  # applied. Sharing a calendar with three people, one address
  # mistyped, must not leave two of them invited with nothing to say
  # which — so the request stands or falls whole and nothing is
  # recorded here.
  defp withheld(conn, invitations, refused) do
    body =
      invitations
      |> Enum.map(&{&1.href, {:status, outcome(&1, refused)}})
      |> Xml.multistatus()
      |> IO.iodata_to_binary()

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(207, body)
  end

  defp outcome(invitation, refused) do
    if invitation in refused,
      do: "HTTP/1.1 403 Forbidden",
      else: "HTTP/1.1 424 Failed Dependency"
  end

  defp invitation(element) do
    %{
      href: href_of(element),
      summary: text_of(element, "summary"),
      state: "noresponse",
      access: access_of(element),
      group: nil
    }
  end

  # A calendar shared with a group is shared with the people in it: a
  # group has no calendar home to bind a view into and no notification
  # collection to be invited through, so the invitation is addressed
  # to each member, who accepts or declines for themselves.
  defp membered(invitation, options) do
    case group_members(invitation.href, options) do
      [] ->
        [Map.put(invitation, :group, nil)]

      members ->
        # Each derived invitation remembers the group it came from, so
        # that unsharing the group withdraws exactly these and leaves
        # a member invited in their own right alone.
        for href <- members, do: %{invitation | href: href, group: invitation.href}
    end
  end

  # A group may hold groups. What a share to it reaches is the people
  # at the leaves, found once and without revisiting a group that
  # appears twice in the graph — or a group that contains itself.
  defp group_members(href, options), do: group_members(href, options, [])

  defp group_members(href, options, seen) do
    %{store: store, context: context} = options
    mark = canonical(href, options)

    with false <- mark in seen,
         true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{} = principal} <- store.principal(href, context),
         %{} = properties <- stored_properties(principal, options),
         {:hrefs, [_first | _rest] = members} <-
           Map.get(properties, {Xml.dav(), "group-member-set"}) do
      members
      |> Enum.map(&addressed(&1, options))
      |> Enum.flat_map(&reached(&1, options, [mark | seen]))
      |> Enum.uniq_by(&canonical(&1, options))
    else
      _not_a_group -> []
    end
  end

  # A member is a person, or another group standing for its own
  # members.
  defp reached(address, options, seen) do
    case group_members(address, options, seen) do
      [] -> [address]
      nested -> nested
    end
  end

  # A member is named by principal URL; an invitation is addressed to
  # a calendar user address, which is what the notification carries
  # and what the sharee's own reply will quote back.
  defp addressed(principal, %{store: store, context: context} = options) do
    with true <- function_exported?(store, :addresses, 2),
         {:ok, [_one | _more] = addresses} <- store.addresses(principal, context) do
      canonical(Enum.min_by(addresses, &String.length/1), options)
    else
      _unaddressed -> principal
    end
  end

  # `CS:read` or `CS:read-write`; read is the safer default when
  # neither is named, since granting write by accident is the mistake
  # that cannot be undone.
  defp access_of(element) do
    if Enum.any?(element.children, &named?(&1, "read-write")), do: "read-write", else: "read"
  end

  # The invitations live on the calendar as a dead property, which is
  # where `CS:invite` reads them from.
  defp record(calendar, invitations, removals, options) do
    %{store: store, context: context} = options

    if Store.supports?(store, :patch) do
      existing = current(calendar, store, context)

      # A re-invitation replaces the earlier one rather than sitting
      # beside it — the earlier one *from the same source*. Somebody
      # invited in their own right and again through a group holds two
      # shares, and withdrawing either leaves the other standing; a
      # single record per person would make the second invitation
      # erase the first.
      replaced =
        for invitation <- invitations,
            into: MapSet.new(),
            do: source_of(invitation, options)

      dropped =
        for who <- removals, into: MapSet.new(), do: canonical(who, options)

      kept =
        Enum.reject(existing, fn held ->
          MapSet.member?(replaced, source_of(held, options)) or
            MapSet.member?(dropped, canonical(held.href, options))
        end)

      store.patch(calendar, [{:set, invite_property(), encode(kept ++ invitations)}], context)
    end

    :ok
  end

  # What a record is a record *of*: this person, as reached this way.
  defp source_of(invitation, options) do
    {canonical(invitation.href, options),
     invitation |> Map.get(:group) |> then(&(&1 && canonical(&1, options)))}
  end

  # One entry per sharee, whatever reached them: a client asking who
  # this calendar is shared with is asking about people. The strongest
  # share a person holds is the one that describes them.
  defp effective(calendar, options) do
    calendar
    |> current(options.store, options.context)
    |> merged(options)
  end

  defp current(calendar, store, context) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(calendar, context),
         value when is_binary(value) <- Map.get(properties, invite_property()) do
      decode(value)
    else
      _none -> []
    end
  end

  defp invite_property, do: {@namespace, "invite-state"}

  # Stored as text rather than as XML: the property is this server's
  # own bookkeeping, and a store that can hold a string can hold it.
  defp encode(invitations) do
    Enum.map_join(invitations, "\n", fn invitation ->
      Enum.join(
        [
          invitation.href,
          invitation.access,
          invitation.summary,
          Map.get(invitation, :state) || "noresponse",
          Map.get(invitation, :group) || ""
        ],
        "\t"
      )
    end)
  end

  defp decode(value) do
    for line <- String.split(value, "\n", trim: true) do
      case String.split(line, "\t", parts: 5) do
        [href, access, summary, state, group] ->
          %{href: href, access: access, summary: summary, state: state, group: grouped(group)}

        [href, access, summary, state] ->
          %{href: href, access: access, summary: summary, state: state, group: nil}

        [href, access, summary] ->
          %{href: href, access: access, summary: summary, state: "noresponse", group: nil}
      end
    end
  end

  defp grouped(""), do: nil
  defp grouped(group), do: group

  # An invitation records what became of it. Until the invitee
  # answers, every sharer's client shows the same calendar as still
  # pending — and a sharer who cannot tell an accepted invitation from
  # an unanswered one has no way to know whether to ask again.
  defp answered(calendar, address, state, %{store: store, context: context} = options) do
    if Store.supports?(store, :patch) do
      wanted = canonical(address, options)

      updated =
        Enum.map(
          current(calendar, store, context),
          &settled(&1, wanted, state, options)
        )

      store.patch(calendar, [{:set, invite_property(), encode(updated)}], context)
    end

    :ok
  end

  defp settled(invitation, wanted, state, options) do
    if canonical(invitation.href, options) == wanted,
      do: %{invitation | state: state},
      else: invitation
  end

  ## --- notifying --------------------------------------------------

  # The invitee has no reason to poll a calendar they cannot see yet,
  # so the invitation is delivered to their notification collection.
  defp notify(calendar, invitation, options) do
    with %Resource{} = collection <- notifications_of(invitation.href, options),
         %{store: store, context: context} <- options,
         true <- Store.supports?(store, :put) do
      uid = uid_for(calendar, invitation, options)

      stored =
        store.put(
          collection.path ++ [uid <> ".xml"],
          invite_notification(calendar, invitation, uid, options),
          "text/xml",
          context
        )

      typed(stored, store, context)
    end

    :ok
  end

  # A sharee who never answered simply stops being invited: for them
  # the notification *is* the invitation, and leaving it offers a
  # calendar they can no longer reach. One who accepted has the
  # calendar bound into their own home and has already acted on the
  # notice — deleting it would remove the only record of a share they
  # can see disappearing.
  defp uninvite(calendar, href, existing, options) do
    wanted = canonical(href, options)

    case Enum.find(existing, &(canonical(&1.href, options) == wanted)) do
      %{state: "noresponse"} ->
        withdraw(calendar, href, options)

      %{} = invitation ->
        farewell(calendar, invitation, options)
        unbind(calendar, href, options)

      _not_invited ->
        :ok
    end
  end

  # An accepted sharee is told the share is over — an invite-deleted
  # notification, titled the way *they* named the calendar: their
  # client knows it by the display name they gave their view, not by
  # the sharer's summary. Read before `unbind/3` takes the view away.
  defp farewell(calendar, invitation, options) do
    summary = view_summary(calendar, invitation.href, options) || invitation.summary
    notify(calendar, %{invitation | state: "deleted", summary: summary}, options)
  end

  defp view_summary(calendar, href, %{store: store, context: context} = options) do
    with {:ok, home} <- store.principal(href, context),
         {:ok, children} <- store.children(home, context),
         %Resource{} = link <- Enum.find(children, &views?(&1, calendar, options)),
         %{} = properties <- stored_properties(link, options),
         name when is_binary(name) <- Map.get(properties, {"DAV:", "displayname"}) do
      name
    else
      _unnamed -> nil
    end
  end

  # An accepted share that is withdrawn stops being visible. What sits
  # in the sharee's home is a view of the sharer's calendar, not a copy
  # of it — leaving it there offers them a collection they can no
  # longer read, and every listing of their home still counts it.
  defp unbind(calendar, href, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :delete),
         {:ok, home} <- store.principal(href, context),
         {:ok, children} <- store.children(home, context),
         %Resource{} = link <- Enum.find(children, &views?(&1, calendar, options)) do
      store.delete(link, context)
    end

    :ok
  end

  defp views?(%Resource{collection?: true} = resource, calendar, options) do
    with %{} = properties <- stored_properties(resource, options),
         {:hrefs, [shared | _rest]} <- Map.get(properties, {@namespace, "shared-url"}) do
      Store.segments(shared) == calendar.path
    else
      _not_a_view -> false
    end
  end

  defp views?(_resource, _calendar, _options), do: false

  # An uninvited sharee should not be left holding the invitation. The
  # notification is the invitation as far as their client is
  # concerned — leaving it there offers them a calendar they can no
  # longer reach, and accepting it would fail with no explanation.
  defp withdraw(calendar, href, options) do
    with %Resource{} = collection <- notifications_of(href, options),
         %{store: store, context: context} <- options,
         true <- Store.supports?(store, :delete),
         path = collection.path ++ [uid_for(calendar, %{href: href}, options) <> ".xml"],
         {:ok, notification} <- store.resolve(path, context) do
      store.delete(notification, context)
    end

    :ok
  end

  # A notification says what kind it is in a property, not only in its
  # body. A client polling the collection reads `CS:notificationtype`
  # to decide whether a notification is worth fetching at all, and one
  # that answers nothing has to be downloaded to find out.
  defp typed({:ok, _outcome, %Resource{} = resource}, store, context) do
    if Store.supports?(store, :patch) do
      store.patch(
        resource,
        [
          {:set, {@namespace, "notificationtype"}, {:elements, [@namespace], notification_type()}}
        ],
        context
      )
    end

    :ok
  end

  defp typed(_refused, _store, _context), do: :ok

  defp notification_type do
    ~s(<CS:invite-notification xmlns:CS=") <> @namespace <> ~s(" shared-type="calendar"/>)
  end

  # One notification per person per calendar, whatever spelling the
  # invitation used: somebody reached once by name and once through a
  # group has been invited once, and two notices would have their
  # client offer the same calendar twice.
  defp uid_for(calendar, invitation, options) do
    who = canonical(invitation.href, options)

    :crypto.hash(:sha, Resource.href(calendar) <> who) |> Base.encode16(case: :lower)
  end

  defp notifications_of(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context),
         {:ok, children} <- store.children(home, context) do
      Enum.find(children, &(notification() in &1.types))
    else
      _unknown -> nil
    end
  end

  defp invite_notification(calendar, invitation, uid, options) do
    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      ~s(<CS:notification xmlns:D="DAV:" xmlns:CS="),
      @namespace,
      ~s(">),
      "<CS:dtstamp>",
      stamp(),
      "</CS:dtstamp>",
      ~s(<CS:invite-notification shared-type="calendar">),
      "<CS:uid>",
      uid,
      "</CS:uid>",
      "<D:href>",
      escape(canonical(invitation.href, options)),
      "</D:href>",
      "<CS:invite-",
      state_of(invitation),
      "/>",
      "<CS:access><CS:",
      invitation.access,
      "/></CS:access>",
      "<CS:hosturl><D:href>",
      escape(Resource.href(calendar)),
      "</D:href></CS:hosturl>",
      "<CS:organizer><D:href>",
      escape(calendar.owner || ""),
      "</D:href>",
      named(calendar.owner, options),
      "</CS:organizer>",
      "<CS:summary>",
      escape(invitation.summary || ""),
      "</CS:summary>",
      # RFC 4791 section 5.2.3: which components the shared calendar
      # holds. An invitee's client decides whether to offer the
      # calendar at all from this, and one that arrives without it has
      # to guess or fetch the collection it has not yet accepted.
      components_of(calendar, options),
      "</CS:invite-notification>",
      "</CS:notification>"
    ]
    |> IO.iodata_to_binary()
  end

  defp state_of(%{state: state}) when state in ~w(accepted declined deleted), do: state
  defp state_of(_invitation), do: "noresponse"

  # The display name of whoever an address belongs to.
  defp common_name(address, %{store: store, context: context} = options) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{owner: owner}} <- store.principal(address, context) do
      named(owner, options)
    else
      _nameless -> []
    end
  end

  # The invitee's client shows a name, not a URL. The display name is
  # the server's — a sharer's client can spell it however it likes and
  # every invitee would see a different one.
  defp named(nil, _options), do: []

  defp named(principal, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         {:ok, resource} <- resolve_principal(principal, store, context),
         %{} = properties <- store.properties(resource, context),
         name when is_binary(name) <- displayed(properties) do
      ["<CS:common-name>", escape(name), "</CS:common-name>"]
    else
      _nameless -> []
    end
  end

  defp resolve_principal(principal, store, context) do
    store.resolve(Store.segments(URI.parse(principal).path || ""), context)
  end

  defp displayed(properties) do
    case Map.get(properties, {Xml.dav(), "displayname"}) do
      value when is_binary(value) -> value
      {:text, value} -> value
      _absent -> nil
    end
  end

  @component_set {"urn:ietf:params:xml:ns:caldav", "supported-calendar-component-set"}

  defp components_of(calendar, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(calendar, context),
         {:elements, _namespaces, markup} <- Map.get(properties, @component_set) do
      [
        ~s(<C:supported-calendar-component-set xmlns:C="urn:ietf:params:xml:ns:caldav">),
        markup,
        "</C:supported-calendar-component-set>"
      ]
    else
      _unstated ->
        [
          ~s(<C:supported-calendar-component-set xmlns:C="urn:ietf:params:xml:ns:caldav">),
          ~s(<C:comp name="VEVENT"/>),
          "</C:supported-calendar-component-set>"
        ]
    end
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  # An invitee is named however the sharer's client spelled them, and
  # the same person can be addressed several ways. The server records
  # the spelling it uses everywhere else, so a client comparing the
  # invitation against a principal it already knows sees one name.
  defp canonical(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :canonical_address, 2),
         {:ok, canonical} <- store.canonical_address(address, context) do
      canonical
    else
      _not_hosted_here -> address
    end
  end

  ## --- replying ---------------------------------------------------

  # On acceptance the invitee is told where the calendar now lives in
  # *their* home, which is the whole point of the reply: without a URL
  # they have been granted access to something they cannot address.
  defp reply(conn, document, resource, options) do
    accepted? = Enum.any?(document.children, &named?(&1, "invite-accepted"))

    recorded(document, if(accepted?, do: "accepted", else: "declined"), options)
    answer(document, accepted?, options)

    if accepted?,
      do: accepted(conn, document, resource, options),
      else: send_resp(conn, 200, "")
  end

  # A sharer learns the answer the same way the sharee learned of the
  # invitation: a notification in their own collection. Without it the
  # only record of an acceptance is a property on the calendar, which
  # nothing tells the sharer's client to re-read — so a share they
  # offered looks unanswered forever.
  defp answer(document, accepted?, options) do
    with shared when is_binary(shared) <- hosturl(document),
         %{store: store, context: context} <- options,
         {:ok, calendar} <- store.resolve(Store.segments(URI.parse(shared).path || ""), context),
         %Resource{} = collection <- sibling_notifications(calendar, options),
         true <- Store.supports?(store, :put) do
      uid = reply_uid(calendar, document)

      store.put(
        collection.path ++ [uid <> ".xml"],
        reply_notification(document, accepted?),
        "text/xml",
        context
      )
      |> typed(store, context)
    end

    :ok
  end

  # The sharer's notification collection sits beside the calendar they
  # shared, both in their own home.
  defp sibling_notifications(calendar, %{store: store, context: context}) do
    with {:ok, home} <- store.resolve(Enum.drop(calendar.path, -1), context),
         {:ok, children} <- store.children(home, context) do
      Enum.find(children, &(notification() in &1.types))
    else
      _unknown -> nil
    end
  end

  defp reply_uid(calendar, document) do
    :crypto.hash(:sha, Resource.href(calendar) <> "reply" <> (href_of(document) || ""))
    |> Base.encode16(case: :lower)
  end

  defp reply_notification(document, accepted?) do
    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      ~s(<CS:notification xmlns:D="DAV:" xmlns:CS="),
      @namespace,
      ~s(">),
      "<CS:dtstamp>",
      stamp(),
      "</CS:dtstamp>",
      ~s(<CS:invite-reply shared-type="calendar">),
      "<D:href>",
      escape(href_of(document) || ""),
      "</D:href>",
      if(accepted?, do: "<CS:invite-accepted/>", else: "<CS:invite-declined/>"),
      "<CS:hosturl><D:href>",
      escape(hosturl(document) || ""),
      "</D:href></CS:hosturl>",
      "<CS:in-reply-to>",
      escape(text_of(document, "in-reply-to") || ""),
      "</CS:in-reply-to>",
      # Only an acceptance names the calendar: the summary is what the
      # sharee called the view they now hold, and a decline holds
      # nothing. The reference's decline notification carries no
      # summary even when the reply did.
      case {accepted?, text_of(document, "summary")} do
        {true, summary} when is_binary(summary) ->
          ["<CS:summary>", escape(summary), "</CS:summary>"]

        _declined_or_unnamed ->
          ""
      end,
      "<CS:common-name>",
      escape(text_of(document, "common-name") || ""),
      "</CS:common-name>",
      "</CS:invite-reply>",
      "</CS:notification>"
    ]
    |> IO.iodata_to_binary()
  end

  # The answer goes back on the sharer's calendar, where `CS:invite`
  # reads it. The reply names the invitee and the collection it
  # answers for, which is everything needed to find the invitation it
  # belongs to.
  defp recorded(document, state, %{store: store, context: context} = options) do
    with shared when is_binary(shared) <- hosturl(document),
         address when is_binary(address) <- href_of(document),
         {:ok, calendar} <-
           store.resolve(Store.segments(URI.parse(shared).path || ""), context) do
      answered(calendar, address, state, options)
    else
      _nothing_to_record -> :ok
    end
  end

  defp accepted(conn, document, home, options) do
    case hosturl(document) do
      nil ->
        send_resp(conn, 400, "")

      shared ->
        path = free(home.path ++ [Path.basename(shared)], shared, options)
        link(path, shared, options)
        christened(path, document, shared, options)

        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(200, shared_as(path))
    end
  end

  # The view is named from the invitation's summary — the name the
  # sharer offered it under — and is the sharee's to change from
  # there.
  defp christened(path, document, shared, %{store: store, context: context} = options) do
    with true <- is_list(path) and Store.supports?(store, :patch),
         name when is_binary(name) and name != "" <- offered_name(document, shared, options) do
      store.patch(
        %Resource{path: path, collection?: true},
        [{:set, {"DAV:", "displayname"}, name}],
        context
      )
    end

    :ok
  end

  defp offered_name(document, shared, %{store: store, context: context}) do
    text_of(document, "summary") ||
      with {:ok, original} <- store.resolve(Store.segments(shared), context),
           %{summary: summary} <-
             Enum.find(current(original, store, context), &(&1.summary not in [nil, ""])) do
        summary
      else
        _unnamed -> nil
      end
  end

  # Two people may both share a calendar named `calendar`. An
  # invitee's home holds one collection of that name, so the second
  # share takes a suffix — binding it over the first would leave
  # somebody who accepted two invitations with one calendar, and no
  # sign of which they lost.
  defp free(path, shared, options, attempt \\ 0)

  defp free(_path, _shared, _options, attempt) when attempt > 20, do: nil

  defp free(path, shared, options, attempt) do
    candidate = numbered(path, attempt)

    cond do
      not taken?(candidate, options) -> candidate
      already?(candidate, shared, options) -> candidate
      true -> free(path, shared, options, attempt + 1)
    end
  end

  defp numbered(path, 0), do: path
  defp numbered(path, attempt), do: List.replace_at(path, -1, "#{List.last(path)}-#{attempt}")

  defp taken?(path, %{store: store, context: context}) do
    match?({:ok, _resource}, store.resolve(path, context))
  end

  # Accepting the same invitation twice is not a second share: the
  # link already there points at the same calendar, and re-binding it
  # under a new name would give the invitee two views of one thing.
  defp already?(path, shared, %{store: store, context: context}) do
    Store.supports?(store, :origin) and
      store.origin(path, context) == Store.segments(URI.parse(shared).path || "")
  end

  defp hosturl(document) do
    case find(document, "hosturl") do
      nil -> nil
      element -> href_of(element)
    end
  end

  # The shared calendar appears in the invitee's home as a collection
  # of its own, reporting `CS:shared` so a client can tell it apart
  # from one they own.
  defp link(path, shared, %{store: store, context: context}) do
    # A calendar collection, not a plain one. What appears in the
    # invitee's home is a calendar they can query, report on and write
    # to like any other — a bare collection looks like a folder that
    # happens to contain `.ics` files, and every CalDAV request
    # against it fails for the wrong reason.
    created =
      if Store.supports?(store, :mkcalendar),
        do: store.mkcalendar(path, context),
        else: store.mkcol(path, context)

    if match?({:ok, _resource}, created) do
      if Store.supports?(store, :patch) do
        store.patch(
          %Resource{path: path, collection?: true},
          [
            {:set, {@namespace, "shared-url"}, {:hrefs, [shared]}},
            # RFC 6638 section 9.1: a calendar shared to you does not
            # make you busy. Stored rather than computed, so free/busy
            # can see it and the invitee can change their mind.
            {:set, {Xml.caldav(), "schedule-calendar-transp"},
             {:elements, [Xml.caldav()], "<C:transparent/>"}}
          ],
          context
        )
      end
    end

    :ok
  end

  @doc """
  Bind a calendar into the caller's own home.

  Apple's direct sharing: rather than wait for an invitation, someone
  who already has access — as a proxy, or through a group — asks for
  the calendar to appear in their calendar home, and is told where it
  now lives.

  ### Arguments

  * `action` is the `action` query parameter. Only `"share"` is
    handled here.

  * `conn` is the request.

  * `resource` is the calendar being shared.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `{:ok, conn}` carrying a `CS:shared-as` document naming the new
    collection, or a `403` when the caller has no calendar home to
    bind it into.

  * `:unhandled` for any other action.

  """
  @impl Dav.Web.Hook
  @spec action(String.t(), Plug.Conn.t(), Resource.t(), map()) ::
          {:ok, Plug.Conn.t()} | :unhandled
  def action("share", conn, resource, options) do
    with true <- Cal.calendar?(resource),
         true <- entitled?(resource, options),
         %Resource{path: home} <- caller_home(options) do
      path = home ++ [List.last(resource.path)]

      # The link records the calendar's *canonical* address. A share
      # taken out through an aliased path would otherwise point at a
      # spelling only the alias resolver knows.
      link(path, Resource.href(canonical_resource(resource, options)), options)

      {:ok,
       conn
       |> put_resp_content_type("application/xml", "utf-8")
       |> send_resp(200, shared_as(path))}
    else
      _nowhere_to_bind_it -> {:ok, send_resp(conn, 403, "")}
    end
  end

  def action(_other, _conn, _resource, _options), do: :unhandled

  defp canonical_resource(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :origin),
         real when real != resource.path <- store.origin(resource.path, context),
         {:ok, %Resource{} = found} <- store.resolve(real, context) do
      found
    else
      _already_canonical -> resource
    end
  end

  # Direct sharing binds without an invitation, so it is only for
  # somebody who already has access — the owner, or one of their
  # proxies. Anyone else asking is refused, not quietly granted a
  # calendar nobody offered them.
  defp entitled?(resource, options) do
    case Map.get(options, :principal) do
      who when is_binary(who) ->
        named = [who | addresses_of(who, options)]
        who == resource.owner or proxied(resource, named, options) != nil

      _anonymous ->
        false
    end
  end

  # The caller's own calendar home, reached the only way the store
  # offers: a principal has addresses, and an address has a home.
  defp caller_home(%{store: store, context: context} = options) do
    with principal when is_binary(principal) <- Map.get(options, :principal),
         true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(principal, context),
         address when is_binary(address) <- List.first(addresses),
         true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context) do
      home
    else
      _unknown_caller -> nil
    end
  end

  defp shared_as(path) do
    href = Resource.href(%Resource{path: path, collection?: true})

    ~s(<?xml version="1.0" encoding="utf-8"?><CS:shared-as xmlns:D="DAV:" xmlns:CS="#{@namespace}"><D:href>#{escape(href)}</D:href></CS:shared-as>)
  end

  ## --- reading ----------------------------------------------------

  # A dispatcher that had to read the body to route on passes it
  # along; anything else reads it here.
  defp request_body(conn, %{body: body}), do: {:ok, body, conn}
  defp request_body(conn, _options), do: read_body(conn)

  defp resolve(path, %{store: store, context: context}), do: store.resolve(path, context)

  defp children(element, name), do: Enum.filter(element.children, &named?(&1, name))

  defp find(element, name), do: Enum.find(element.children, &named?(&1, name))

  defp href_of(element) do
    case find(element, "href") do
      nil -> nil
      href -> String.trim(href.text)
    end
  end

  defp text_of(element, name) do
    case find(element, name) do
      nil -> nil
      found -> String.trim(found.text)
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
