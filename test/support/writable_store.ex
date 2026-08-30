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
  alias Dav.Web.Resource

  @sharing "http://calendarserver.org/ns/"

  # Where this store's clock starts. Every write advances it a second,
  # so an object written later is later, and a collection with nothing
  # in it is still *as of* something.
  @epoch ~U[2020-01-01 00:00:00Z]

  def start(resources) do
    {:ok, agent} = Agent.start_link(fn -> %{resources: resources, bodies: %{}, dead: %{}} end)
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

    {:ok, merged(shared, mine(agent, held))}
  end

  @impl Dav.Web.Store
  def put(path, body, content_type, agent) do
    held = underlying(agent, path)

    if exists?(agent, Enum.drop(held, -1)) do
      {shared, personal} = divided(agent, held, body)

      keep_personal(agent, held, personal)
      store(agent, held, shared, content_type)
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

  defp keep_personal(_agent, _held, nil), do: :ok

  defp keep_personal(agent, held, personal) do
    who = asking(agent)

    Agent.update(pid(agent), fn state ->
      Map.update(
        state,
        :personal,
        %{{held, who} => personal},
        &Map.put(&1, {held, who}, personal)
      )
    end)
  end

  defp mine(agent, held) do
    case asking(agent) do
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

  @impl Dav.Web.Store
  def delete(%Resource{path: path}, agent) do
    Agent.update(pid(agent), fn state ->
      # Dead properties die with the resource. A share is recorded as
      # one — a `CS:shared-url` naming what the link points at — so
      # leaving them behind means a sharee who deletes a shared
      # calendar still resolves it through the link that is no longer
      # there.
      %{
        state
        | resources: Enum.reject(state.resources, &beneath?(&1.path, path)),
          bodies: Map.reject(state.bodies, fn {held, _body} -> beneath?(held, path) end),
          dead: Map.reject(state.dead, fn {held, _properties} -> beneath?(held, path) end)
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
    resource = %Resource{path: path, collection?: true, owner: inherited(agent, path)}
    Agent.update(pid(agent), &%{&1 | resources: &1.resources ++ [resource]})
    {:ok, resource}
  end

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

  @impl Dav.Web.Store
  def properties(%Resource{path: path}, agent) do
    held = aliased(agent, path)

    Agent.get(pid(agent), &Map.get(&1.dead, held, %{}))
  end

  # Atomic by construction: the new map is computed in full and only
  # then written, so a refusal leaves the old one untouched.
  @impl Dav.Web.Store
  def patch(%Resource{path: path}, instructions, agent) do
    path = aliased(agent, path)
    current = Agent.get(pid(agent), &Map.get(&1.dead, path, %{}))

    updated =
      Enum.reduce(instructions, current, fn
        {:set, name, value}, acc -> Map.put(acc, name, value)
        {:remove, name}, acc -> Map.delete(acc, name)
      end)

    Agent.update(pid(agent), &%{&1 | dead: Map.put(&1.dead, path, updated)})
    :ok
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
    :ok
  end

  # Both are the same operation over the subtree; a move also forgets
  # where it came from.
  defp transplant(state, from, to, source) do
    depth = length(from)
    under = fn path -> Enum.take(path, depth) == from end
    rebase = fn path -> to ++ Enum.drop(path, depth) end

    copied = for r <- state.resources, under.(r.path), do: %{r | path: rebase.(r.path)}
    bodies = for {p, b} <- state.bodies, under.(p), into: %{}, do: {rebase.(p), b}

    kept =
      case source do
        :keep -> state.resources
        :drop -> Enum.reject(state.resources, &under.(&1.path))
      end

    kept_bodies =
      case source do
        :keep -> state.bodies
        :drop -> Map.reject(state.bodies, fn {p, _b} -> under.(p) end)
      end

    landing = for r <- copied, do: r.path

    %{
      state
      | resources: copied ++ Enum.reject(kept, &(&1.path in landing)),
        bodies: Map.merge(kept_bodies, bodies)
    }
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
      owner: inherited(agent, path)
    }

    Agent.update(pid(agent), &%{&1 | resources: &1.resources ++ [resource]})
    {:ok, resource}
  end

  defp calendar?(_agent, []), do: false

  defp calendar?(agent, path) do
    Agent.get(pid(agent), fn state ->
      Enum.any?(state.resources, &(&1.path == path and Cal.calendar() in &1.types))
    end)
  end
end
