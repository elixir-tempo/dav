defmodule Dav.Test.WritableStore do
  @moduledoc """
  A store in an Agent, implementing the optional write callbacks.

  Its read-only sibling `Dav.Test.MemoryStore` implements none of them,
  which is how the tests check that a store's capabilities and the
  server's `Allow` header stay in step.
  """

  @behaviour Dav.Web.Store

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Cal.Sharing
  alias Dav.Web.Resource

  @sharing "http://calendarserver.org/ns/"

  # Where this store's clock starts. Every write advances it a second,
  # so an object written later is later, and a collection with nothing
  # in it is still *as of* something.
  @epoch ~U[2020-01-01 00:00:00Z]

  def start(resources) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{resources: resources, bodies: %{}, dead: %{}, graveyard: %{}}
      end)

    agent
  end

  @impl Dav.Web.Store
  def scope(agent, principal), do: {pid(agent), principal}

  # The context is either the bare agent, as a store is configured
  # with, or the pair the plug asked for at the edge. Both name the
  # same store; only the second knows who is looking at it.
  @doc """
  The agent named by a context, scoped or not.

  ### Arguments

  * `context` is either the bare agent or the `{agent, principal}`
    pair `c:Dav.Web.Store.scope/2` produced.

  ### Returns

  * The agent.

  """
  def pid({agent, _principal}), do: agent
  def pid(agent), do: agent

  defp asking({_agent, principal}), do: principal
  defp asking(_agent), do: nil

  @impl Dav.Web.Store
  def origin(path, agent), do: underlying(agent, path)

  @impl Dav.Web.Store
  def resolve(path, agent) do
    case Agent.get(pid(agent), &Enum.find(&1.resources, fn r -> r.path == path end)) do
      nil -> resolve_through(path, agent)
      resource -> {:ok, dated(resource, agent)}
    end
  end

  # A collection is as new as the newest thing in it. Without this it
  # has no `Last-Modified` at all, and a client asking "has anything
  # changed here since?" — which is how a calendar is polled — can only
  # be told to fetch the lot.
  defp dated(%Resource{collection?: true} = collection, agent) do
    under =
      for %{path: path, modified_at: %DateTime{} = at} <- Agent.get(pid(agent), & &1.resources),
          path != collection.path,
          Enum.take(path, length(collection.path)) == collection.path,
          do: at

    # An empty collection is still *as of* something. Leaving it without
    # a `Last-Modified` means a client cannot ask whether it has
    # changed, and has to fetch it to find out that it has not.
    %{
      collection
      | modified_at: Enum.max(under, DateTime, fn -> collection.modified_at || @epoch end)
    }
  end

  defp dated(resource, _agent), do: resource

  defp name_of_instruction({:set, name, _value}), do: name
  defp name_of_instruction({:remove, name}), do: name

  # The asker, when the thing patched is not their own — the owner's
  # writes stay the shared default everyone else reads through.
  defp foreign_asker(agent, path) do
    with who when is_binary(who) <- asking(agent),
         owner when is_binary(owner) <- owner_above(agent, path),
         false <- owner == who do
      who
    else
      _own_or_nobody -> nil
    end
  end

  defp owner_above(agent, path) do
    resources = Agent.get(pid(agent), & &1.resources)

    Enum.find_value(length(path)..1//-1, fn depth ->
      prefix = Enum.take(path, depth)
      Enum.find_value(resources, &owner_at(&1, prefix))
    end)
  end

  defp owner_at(%Resource{path: path, owner: owner}, path), do: owner
  defp owner_at(_resource, _prefix), do: nil

  defp patch_overlay(agent, path, instructions) do
    who = asking(agent)

    Agent.update(pid(agent), fn state ->
      overlays = Map.get(state, :overlays, %{})
      mine = overlays |> Map.get(who, %{}) |> Map.get(path, %{})

      updated =
        Enum.reduce(instructions, mine, fn
          {:set, name, value}, acc -> Map.put(acc, name, value)
          {:remove, name}, acc -> Map.delete(acc, name)
        end)

      held = overlays |> Map.get(who, %{}) |> Map.put(path, updated)
      Map.put(state, :overlays, Map.put(overlays, who, held))
    end)
  end

  # A shared calendar is a view, not a copy. What sits in the
  # invitee's home is a link recording where the original lives, and a
  # resource addressed inside it is the sharer's resource seen from
  # there. Storing a second copy instead would let the two disagree
  # the moment either party wrote to one.
  defp resolve_through(path, agent) do
    case underlying(agent, path) do
      ^path ->
        {:error, :not_found}

      target ->
        with {:ok, resource} <- resolve(target, agent), do: {:ok, %{resource | path: path}}
    end
  end

  # The path as the store holds it. A path under a link is rewritten
  # onto the collection the link points at; anything else is itself.
  defp underlying(agent, path) do
    state = Agent.get(pid(agent), & &1)
    aliases = Map.get(state, :aliases, %{})

    path
    |> ancestors()
    |> Enum.find_value(path, &redirected(&1, path, aliases, state.dead))
  end

  defp redirected(prefix, path, aliases, dead) do
    case {Map.fetch(aliases, prefix), linked(dead, prefix)} do
      {{:ok, target}, _link} -> target ++ Enum.drop(path, length(prefix))
      {:error, nil} -> nil
      {:error, target} -> target ++ Enum.drop(path, length(prefix))
    end
  end

  defp linked(dead, prefix) do
    case dead |> Map.get(prefix, %{}) |> Map.get({@sharing, "shared-url"}) do
      {:hrefs, [href | _rest]} -> shared_path(href)
      _not_a_link -> nil
    end
  end

  # Only the second name for the same collection, never a share link.
  # A link's own properties — where it points, who was invited, how
  # busy it makes them — belong to the link, and reading the
  # original's instead would leave it looking like nobody's share.
  defp aliased(agent, path) do
    aliases = Agent.get(pid(agent), &Map.get(&1, :aliases, %{}))

    path
    |> ancestors()
    |> Enum.find_value(path, fn prefix ->
      case Map.fetch(aliases, prefix) do
        {:ok, target} -> target ++ Enum.drop(path, length(prefix))
        :error -> nil
      end
    end)
  end

  # Longest first: a link inside a link resolves against the nearest.
  defp ancestors(path) do
    for taken <- length(path)..1//-1, do: Enum.take(path, taken)
  end

  defp shared_path(href), do: href |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

  @impl Dav.Web.Store
  def children(%Resource{path: path}, agent) do
    held = underlying(agent, path)
    depth = length(held) + 1

    listed =
      Agent.get(pid(agent), fn state ->
        Enum.filter(state.resources, fn r ->
          length(r.path) == depth and Enum.take(r.path, length(held)) == held
        end)
      end)

    # Listed under the link, not under the original. A member of a
    # shared calendar is addressed inside the invitee's home, and
    # returning the sharer's paths would send the client somewhere it
    # may not look.
    {:ok, for(child <- listed, do: %{child | path: path ++ Enum.drop(child.path, length(held))})}
  end

  @impl Dav.Web.Store
  def read(%Resource{path: path}, agent) do
    held = underlying(agent, path)
    shared = Agent.get(pid(agent), &Map.get(&1.bodies, held, ""))

    {:ok, merged(shared, mine(agent, held, acting_of(agent, path)))}
  end

  # Whose view this is. A path in somebody's home shows their view of
  # the thing — a proxy writing or reading through it acts as them,
  # and the alarms land on the right person's phone.
  defp acting_of(agent, path), do: owner_above(agent, path) || asking(agent)

  @impl Dav.Web.Store
  def put(path, body, content_type, agent) do
    held = underlying(agent, path)

    if exists?(agent, Enum.drop(held, -1)) do
      {shared, personal} = divided(agent, held, body)

      keep_personal(agent, held, personal, acting_of(agent, path))

      # Answered at the path the caller wrote to: a later write derived
      # from this one — a hook restating the body — lands on the same
      # spelling, and so acts as the same person.
      with {:ok, outcome, resource} <- store(agent, held, shared, content_type) do
        {:ok, outcome, %{resource | path: path}}
      end
    else
      {:error, :conflict}
    end
  end

  # A shared calendar object has a part everyone sees and a part each
  # person sees alone. Whether you are busy during a meeting, and
  # whether you want warning of it, are answers about you rather than
  # about the meeting — the reference server keys them by principal
  # (`X-CALENDARSERVER-PERUSER-UID`) and merges them back per reader.
  # Writing them into the shared body instead lets one sharee's alarm
  # ring on everyone else's phone.
  @epoch ~U[2020-01-01 00:00:00Z]

  @personal_properties ~w(TRANSP)
  @personal_components ~w(VALARM)

  defp divided(agent, held, body) do
    with who when is_binary(who) <- asking(agent),
         true <- shared?(agent, held),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(body)) do
      {ICalendar.write(without_personal(calendar)), personal_of(calendar)}
    else
      _private_or_unreadable -> {body, nil}
    end
  end

  defp without_personal(calendar) do
    %{calendar | components: Enum.map(calendar.components, &stripped/1)}
  end

  defp stripped(%{name: "VTIMEZONE"} = zone), do: zone

  defp stripped(component) do
    %{
      component
      | properties: Enum.reject(component.properties, &(&1.name in @personal_properties)),
        components: Enum.reject(component.components, &(&1.name in @personal_components))
    }
  end

  defp personal_of(calendar) do
    for component <- calendar.components,
        component.name != "VTIMEZONE",
        into: %{},
        do:
          {recurrence(component),
           {Enum.filter(component.properties, &(&1.name in @personal_properties)),
            Enum.filter(component.components, &(&1.name in @personal_components))}}
  end

  defp recurrence(component) do
    case Enum.find(component.properties, &(&1.name == "RECURRENCE-ID")) do
      nil -> nil
      property -> property.value
    end
  end

  defp keep_personal(_agent, _held, nil, _who), do: :ok

  defp keep_personal(agent, held, personal, who) do
    Agent.update(pid(agent), fn state ->
      Map.update(
        state,
        :personal,
        %{{held, who} => personal},
        &Map.put(&1, {held, who}, personal)
      )
    end)
  end

  defp mine(agent, held, who) do
    case who do
      nil -> nil
      who -> Agent.get(pid(agent), &(&1 |> Map.get(:personal, %{}) |> Map.get({held, who})))
    end
  end

  defp merged(shared, nil), do: shared

  defp merged(shared, personal) do
    case ICalendar.parse(IO.iodata_to_binary(shared)) do
      {:ok, calendar} -> ICalendar.write(%{calendar | components: restored(calendar, personal)})
      _unreadable -> shared
    end
  end

  defp restored(calendar, personal) do
    for component <- calendar.components do
      case component.name != "VTIMEZONE" && Map.get(personal, recurrence(component)) do
        {properties, components} ->
          %{
            component
            | properties: component.properties ++ properties,
              components: component.components ++ components
          }

        _none ->
          component
      end
    end
  end

  # A collection somebody has shared, either as the original or as the
  # link standing in for it.
  defp shared?(agent, held) do
    collection = Enum.drop(held, -1)
    dead = Agent.get(pid(agent), & &1.dead)

    Map.has_key?(Map.get(dead, collection, %{}), {@sharing, "shared-url"}) or
      Enum.any?(dead, fn {_path, properties} ->
        case Map.get(properties, {@sharing, "shared-url"}) do
          {:hrefs, [href | _rest]} -> shared_path(href) == collection
          _not_a_link -> false
        end
      end)
  end

  # A store says when each resource was last written, and a client
  # reading a collection uses it to find what has just arrived —
  # CalDAVTester's `GETNEW` is exactly that. Wall-clock time cannot
  # serve here: a scenario writes many resources inside one second and
  # they would all claim the same instant, so the clock advances a
  # second per write and the order of writing is the order reported.
  defp written(agent) do
    seconds =
      Agent.get_and_update(pid(agent), fn state ->
        {Map.get(state, :written, 0) + 1, Map.update(state, :written, 1, &(&1 + 1))}
      end)

    DateTime.add(@epoch, seconds, :second)
  end

  defp store(agent, path, body, content_type) do
    existed? = exists?(agent, path)

    resource = %Resource{
      path: path,
      content_type: content_type,
      content_length: byte_size(body),
      etag: ~s("#{:erlang.phash2(body)}"),
      modified_at: written(agent)
    }

    Agent.update(pid(agent), fn state ->
      %{
        state
        | resources: Enum.reject(state.resources, &(&1.path == path)) ++ [resource],
          bodies: Map.put(state.bodies, path, body)
      }
    end)

    {:ok, if(existed?, do: :replaced, else: :created), resource}
  end

  # A member addressed through a share link is the sharer's resource:
  # deleting it deletes the original. The link itself is the sharee's
  # own — deleting a shared calendar's view removes the view, and the
  # sharer's calendar stays where it was.
  @impl Dav.Web.Store
  def delete(%Resource{path: path}, agent) do
    path = if view?(agent, path), do: path, else: underlying(agent, path)
    stamp = DateTime.diff(written(agent), @epoch)

    Agent.update(pid(agent), fn state ->
      # What a deletion removes, synchronisation must still be able to
      # name: a client holding an older token is told which members
      # are gone, not left to notice their absence.
      buried =
        for resource <- state.resources,
            beneath?(resource.path, path),
            into: Map.get(state, :graveyard, %{}),
            do: {resource.path, stamp}

      # Dead properties die with the resource. A share is recorded as
      # one — a `CS:shared-url` naming what the link points at — so
      # leaving them behind means a sharee who deletes a shared
      # calendar still resolves it through the link that is no longer
      # there.
      %{
        state
        | resources: Enum.reject(state.resources, &beneath?(&1.path, path)),
          bodies: Map.reject(state.bodies, fn {held, _body} -> beneath?(held, path) end),
          dead: Map.reject(state.dead, fn {held, _properties} -> beneath?(held, path) end),
          graveyard: buried
      }
    end)

    :ok
  end

  defp beneath?(held, path), do: Enum.take(held, length(path)) == path

  @impl Dav.Web.Store
  def mkcol(path, agent) do
    cond do
      exists?(agent, path) -> {:error, :exists}
      not exists?(agent, Enum.drop(path, -1)) -> {:error, :conflict}
      true -> create(agent, path)
    end
  end

  # A collection belongs to whoever owns the one it was made in. A
  # calendar created inside someone's calendar home is theirs, and
  # without an owner nothing can tell whose it is — implicit
  # scheduling reads the owner to decide which way a message goes, so
  # an ownerless calendar accepts invitations and delivers none.
  defp create(agent, path) do
    resource = %Resource{
      path: path,
      collection?: true,
      owner: inherited(agent, path),
      modified_at: written(agent)
    }

    Agent.update(pid(agent), &born(&1, resource))
    {:ok, resource}
  end

  # A collection's birth is not its last change: a property write
  # moves its revision and leaves its birth alone.
  defp born(state, resource) do
    %{state | resources: state.resources ++ [resource]}
    |> Map.put(:births, Map.put(births(state), resource.path, revision(resource)))
  end

  defp births(state), do: Map.get(state, :births, %{})

  defp inherited(agent, path) do
    parent = Enum.drop(path, -1)

    Agent.get(pid(agent), fn state ->
      case Enum.find(state.resources, &(&1.path == parent)) do
        %Resource{owner: owner} -> owner
        nil -> nil
      end
    end)
  end

  defp exists?(_agent, []), do: true

  defp exists?(agent, path) do
    Agent.get(pid(agent), &Enum.any?(&1.resources, fn r -> r.path == path end))
  end

  # The properties Apple keeps per person even on a shared thing: a
  # proxy's calendar colour is their own, layered over the owner's.
  @per_user [
    {"http://apple.com/ns/ical/", "calendar-color"},
    {"http://apple.com/ns/ical/", "calendar-order"}
  ]

  @impl Dav.Web.Store
  def properties(%Resource{path: path}, agent) do
    held = aliased(agent, path)
    shared = Agent.get(pid(agent), &Map.get(&1.dead, held, %{}))

    case asking(agent) do
      nil -> shared
      who -> Map.merge(shared, overlay_for(agent, who, held))
    end
  end

  defp overlay_for(agent, who, path) do
    Agent.get(pid(agent), fn state ->
      state |> Map.get(:overlays, %{}) |> Map.get(who, %{}) |> Map.get(path, %{})
    end)
  end

  # Atomic by construction: the new map is computed in full and only
  # then written, so a refusal leaves the old one untouched.
  @impl Dav.Web.Store
  def patch(%Resource{path: path}, instructions, agent) do
    path = aliased(agent, path)

    {personal, common} =
      case foreign_asker(agent, path) do
        nil -> {[], instructions}
        _who -> Enum.split_with(instructions, &(name_of_instruction(&1) in @per_user))
      end

    if personal != [], do: patch_overlay(agent, path, personal)

    current = Agent.get(pid(agent), &Map.get(&1.dead, path, %{}))

    updated =
      Enum.reduce(common, current, fn
        {:set, name, value}, acc -> Map.put(acc, name, value)
        {:remove, name}, acc -> Map.delete(acc, name)
      end)

    # A property change is a change: a client synchronising a home is
    # told which calendar was renamed or newly shared, not only which
    # gained a member.
    stamp = written(agent)
    origin = underlying(agent, path)

    Agent.update(pid(agent), fn state ->
      %{
        state
        | dead: Map.put(state.dead, path, updated),
          resources: Enum.map(state.resources, &touched(&1, [path, origin], stamp))
      }
    end)

    :ok
  end

  defp touched(%Resource{} = resource, paths, stamp) do
    if resource.path in paths, do: %{resource | modified_at: stamp}, else: resource
  end

  @impl Dav.Web.Store
  def copy(%Resource{path: from}, to, agent) do
    {held, target} = {underlying(agent, from), underlying(agent, to)}

    Agent.update(pid(agent), fn state -> transplant(state, held, target, :keep) end)
    :ok
  end

  # Both ends go through the link. A sharee moving an event into a
  # calendar shared with them is writing to the sharer's collection —
  # the path in their own home is a view of it — and a move that
  # landed at the view's path would put the event somewhere neither
  # party can read.
  @impl Dav.Web.Store
  def move(%Resource{path: from}, to, agent) do
    {held, target} = {underlying(agent, from), underlying(agent, to)}

    Agent.update(pid(agent), fn state -> transplant(state, held, target, :drop) end)
    settle_personal(agent, target)
    :ok
  end

  # A body moved into a shared collection carries per-user data it
  # acquired somewhere private. Landing it splits the copy the same
  # way a direct write would — the mover keeps their `TRANSP` and
  # alarms, the other sharees never see them.
  defp settle_personal(agent, target) do
    with who when is_binary(who) <- asking(agent),
         true <- shared?(agent, target),
         body when is_binary(body) <- Agent.get(pid(agent), &Map.get(&1.bodies, target)),
         {:ok, calendar} <- ICalendar.parse(body) do
      shared = ICalendar.write(without_personal(calendar))

      Agent.update(pid(agent), fn state ->
        %{state | bodies: Map.put(state.bodies, target, IO.iodata_to_binary(shared))}
      end)

      keep_personal(agent, target, personal_of(calendar), asking(agent))
    end

    :ok
  end

  # Both are the same operation over the subtree; a move also forgets
  # where it came from — except the identities, which are the point:
  # `DAV:resource-id` names the resource wherever it is bound.
  defp transplant(state, from, to, source) do
    depth = length(from)
    under = fn path -> Enum.take(path, depth) == from end
    rebase = fn path -> to ++ Enum.drop(path, depth) end

    copied = for r <- state.resources, under.(r.path), do: %{r | path: rebase.(r.path)}
    bodies = for {p, b} <- state.bodies, under.(p), into: %{}, do: {rebase.(p), b}
    dead = for {p, d} <- state.dead, under.(p), into: %{}, do: {rebase.(p), d}

    state = identities_carried(state, source, under, rebase)
    {kept, kept_bodies, kept_dead} = remaining(state, source, under)
    landing = for r <- copied, do: r.path

    %{
      state
      | resources: copied ++ Enum.reject(kept, &(&1.path in landing)),
        bodies: Map.merge(kept_bodies, bodies),
        dead: Map.merge(kept_dead, dead)
    }
  end

  # What the source keeps of itself: everything on a copy, nothing on
  # a move. Dead properties travel with the resource either way — the
  # reference copies the property store alongside the body, and an
  # access mark or attachment reference must not fall off in transit.
  defp remaining(state, :keep, _under), do: {state.resources, state.bodies, state.dead}

  defp remaining(state, :drop, under) do
    {Enum.reject(state.resources, &under.(&1.path)),
     Map.reject(state.bodies, fn {p, _b} -> under.(p) end),
     Map.reject(state.dead, fn {p, _d} -> under.(p) end)}
  end

  defp identities_carried(state, :keep, _under, _rebase), do: state

  defp identities_carried(state, :drop, under, rebase) do
    moved =
      for {p, id} <- Map.get(state, :identities, %{}),
          into: %{},
          do: {if(under.(p), do: rebase.(p), else: p), id}

    Map.put(state, :identities, moved)
  end

  # A principal's identity is its stable uid; anything else gets one
  # minted the first time somebody asks, and keeps it across `MOVE`.
  @impl Dav.Web.Store
  def resource_id(%Resource{} = resource, agent) do
    case principal_identity(resource) do
      identity when is_binary(identity) -> identity
      nil -> minted_identity(resource, agent)
    end
  end

  defp principal_identity(%Resource{owner: owner}) when is_binary(owner) do
    case owner |> String.trim("/") |> String.split("/") do
      ["principals", "__uids__", guid] -> "urn:x-uid:" <> guid
      _other_shape -> nil
    end
  end

  defp principal_identity(_resource), do: nil

  defp minted_identity(%Resource{path: path}, agent) do
    held = underlying(agent, path)

    Agent.get_and_update(pid(agent), fn state ->
      identities = Map.get(state, :identities, %{})

      case Map.fetch(identities, held) do
        {:ok, identity} ->
          {identity, state}

        :error ->
          identity =
            "urn:x-dav:" <>
              Integer.to_string(:erlang.phash2({held, map_size(identities)}, 4_294_967_296))

          {identity, Map.put(state, :identities, Map.put(identities, held, identity))}
      end
    end)
  end

  @impl Dav.Web.Store
  def mkcalendar(path, agent) do
    parent = Enum.drop(path, -1)

    cond do
      exists?(agent, path) -> {:error, :exists}
      not exists?(agent, parent) -> {:error, :conflict}
      # RFC 4791: a calendar collection MUST NOT contain another.
      calendar?(agent, parent) -> {:error, :forbidden}
      true -> create_calendar(agent, path)
    end
  end

  defp create_calendar(agent, path) do
    resource = %Resource{
      path: path,
      collection?: true,
      types: [Cal.calendar()],
      owner: inherited(agent, path),
      modified_at: written(agent)
    }

    Agent.update(pid(agent), &born(&1, resource))
    {:ok, resource}
  end

  # The token is the newest revision *beneath this collection*, not
  # the store's clock: a write elsewhere moves neither this token nor
  # the `CS:getctag` derived from it.
  @impl Dav.Web.Store
  def sync_token(%Resource{} = collection, agent) do
    if synchronised?(collection, agent) do
      "data:," <> Integer.to_string(subtree_revision(collection, agent))
    end
  end

  @impl Dav.Web.Store
  def changes(%Resource{} = collection, nil, scope, agent) do
    {:ok, sync_token(collection, agent), altered(collection, -1, scope, agent),
     unsynced(collection, agent)}
  end

  def changes(%Resource{} = collection, token, scope, agent) do
    with {:ok, since} <- since(token, agent),
         :ok <- syncable_across(collection, since, scope, agent) do
      {:ok, sync_token(collection, agent), altered(collection, since, scope, agent),
       buried_since(collection, since, scope, agent)}
    else
      _stale_or_crossed -> {:error, :invalid_sync_token}
    end
  end

  @dropbox {@sharing, "dropbox-home"}

  # The reference server keeps the attachment dropbox out of home
  # synchronisation, and answers `404` for it in an initial report so
  # a client learns not to sync it here rather than inferring it from
  # absence. A difference stays quiet about it — the client was
  # already told.
  defp unsynced(%Resource{} = collection, agent) do
    {:ok, members} = children(collection, agent)
    for member <- members, @dropbox in member.types, do: member.path
  end

  # The reference server refuses a `:tree` difference across a share
  # link that appeared since the token: the linked collection's history
  # is not expressible against the old view of the home, and the client
  # is sent back for an initial synchronisation instead.
  defp syncable_across(%Resource{} = collection, since, :tree, agent) do
    {:ok, members} = children(collection, agent)

    crossed? =
      home?(collection, agent) and
        Enum.any?(members, fn member ->
          member.collection? and view?(agent, member.path) and born_after?(member, since, agent)
        end)

    if crossed?, do: :crossed, else: :ok
  end

  defp syncable_across(_collection, _since, _scope, _agent), do: :ok

  defp view?(agent, path) do
    Agent.get(pid(agent), &linked(&1.dead, path)) != nil
  end

  defp born_after?(%Resource{path: path} = member, since, agent) do
    Agent.get(pid(agent), &Map.get(births(&1), path, revision(member))) > since
  end

  # The collections whose membership this store keeps a history for:
  # calendars, the scheduling Inbox, the notification collection, and
  # the home that holds them — the collections a calendar client polls.
  defp synchronised?(%Resource{collection?: true} = collection, agent) do
    Cal.calendar?(collection) or Schedule.inbox() in collection.types or
      Sharing.notification() in collection.types or home?(collection, agent)
  end

  defp synchronised?(_resource, _agent), do: false

  # A home is known by what it holds: the collection whose immediate
  # members include a calendar. The container *above* the homes holds
  # only other containers, and is not synchronised.
  defp home?(%Resource{path: path}, agent) do
    held = underlying(agent, path)
    depth = length(held) + 1

    Agent.get(pid(agent), fn state ->
      Enum.any?(state.resources, fn resource ->
        length(resource.path) == depth and
          Enum.take(resource.path, length(held)) == held and
          Cal.calendar() in resource.types
      end)
    end)
  end

  # A member that changed since the token. An object answers for
  # itself; a collection answers for its subtree — a home reports the
  # calendar something changed *in*, and at `:tree` scope also what
  # changed inside it.
  defp altered(%Resource{} = collection, since, scope, agent) do
    {:ok, members} = children(collection, agent)
    Enum.flat_map(members, &altered_member(&1, since, scope, agent))
  end

  defp altered_member(member, since, scope, agent) do
    cond do
      @dropbox in member.types ->
        []

      not member.collection? ->
        if revision(member) > since, do: [member], else: []

      scope == :tree ->
        named(member, since, agent) ++ altered(member, since, scope, agent)

      true ->
        named(member, since, agent)
    end
  end

  defp named(%Resource{} = collection, since, agent) do
    if subtree_revision(collection, agent) > since, do: [collection], else: []
  end

  defp subtree_revision(%Resource{} = collection, agent) do
    {:ok, members} = children(collection, agent)

    below =
      for member <- members,
          do: if(member.collection?, do: subtree_revision(member, agent), else: revision(member))

    Enum.max(
      [revision(collection), origin_revision(collection, agent) | below] ++
        stamps_under(collection, agent)
    )
  end

  # A view answers for the collection it points at: a property the
  # sharer changed on the original moves the view's revision too.
  defp origin_revision(%Resource{path: path}, agent) do
    case underlying(agent, path) do
      ^path ->
        0

      held ->
        Agent.get(pid(agent), fn state ->
          Enum.find(state.resources, &(&1.path == held))
        end)
        |> case do
          %Resource{} = original -> revision(original)
          nil -> 0
        end
    end
  end

  # Deletions count as changes to the collection they emptied.
  defp stamps_under(%Resource{path: path}, agent) do
    held = underlying(agent, path)

    for {buried_path, stamp} <- Agent.get(pid(agent), &Map.get(&1, :graveyard, %{})),
        Enum.take(buried_path, length(held)) == held,
        buried_path != held,
        do: stamp
  end

  defp buried_since(%Resource{} = collection, since, scope, agent) do
    {:ok, members} = children(collection, agent)

    nested =
      if scope == :tree do
        for member <- members,
            member.collection?,
            gone <- buried_since(member, since, scope, agent),
            do: gone
      else
        []
      end

    buried(collection, since, members, agent) ++ nested
  end

  # A token this store issued names a point on its write clock. One it
  # never issued — or one from a future it has not reached — is not a
  # point to diff against.
  defp since("data:," <> digits, agent) do
    case Integer.parse(digits) do
      {count, ""} ->
        if count <= Agent.get(pid(agent), &Map.get(&1, :written, 0)),
          do: {:ok, count},
          else: :error

      _not_a_count ->
        :error
    end
  end

  defp since(_token, _agent), do: :error

  defp revision(%Resource{modified_at: %DateTime{} = at}), do: DateTime.diff(at, @epoch)
  defp revision(_resource), do: 0

  # The members deleted since the token, by the name they had here. A
  # member deleted and then written again is alive, and reported among
  # the changed rather than the removed. A collection deleted and then
  # made again answers only for its new life: the members that died
  # with the old one were never in this collection.
  defp buried(%Resource{path: path} = collection, since, members, agent) do
    held = underlying(agent, path)
    alive = MapSet.new(members, & &1.path)
    graveyard = Agent.get(pid(agent), &Map.get(&1, :graveyard, %{}))
    rebirth = Map.get(graveyard, held, -1)

    for {buried_path, stamp} <- graveyard,
        length(buried_path) == length(held) + 1,
        Enum.take(buried_path, length(held)) == held,
        stamp > since,
        stamp > rebirth,
        renamed = collection.path ++ [List.last(buried_path)],
        renamed not in alive,
        do: renamed
  end

  defp calendar?(_agent, []), do: false

  defp calendar?(agent, path) do
    Agent.get(pid(agent), fn state ->
      Enum.any?(state.resources, &(&1.path == path and Cal.calendar() in &1.types))
    end)
  end
end
