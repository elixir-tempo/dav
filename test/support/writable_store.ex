defmodule Dav.Test.WritableStore do
  @moduledoc """
  A store in an Agent, implementing the optional write callbacks.

  Its read-only sibling `Dav.Test.MemoryStore` implements none of them,
  which is how the tests check that a store's capabilities and the
  server's `Allow` header stay in step.
  """

  @behaviour Dav.Web.Store

  alias Dav.Cal
  alias Dav.Web.Resource

  def start(resources) do
    {:ok, agent} = Agent.start_link(fn -> %{resources: resources, bodies: %{}, dead: %{}} end)
    agent
  end

  @impl Dav.Web.Store
  def resolve(path, agent) do
    case Agent.get(agent, &Enum.find(&1.resources, fn r -> r.path == path end)) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  @impl Dav.Web.Store
  def children(%Resource{path: path}, agent) do
    depth = length(path) + 1

    {:ok,
     Agent.get(agent, fn state ->
       Enum.filter(state.resources, fn r ->
         length(r.path) == depth and Enum.take(r.path, length(path)) == path
       end)
     end)}
  end

  @impl Dav.Web.Store
  def read(%Resource{path: path}, agent) do
    {:ok, Agent.get(agent, &Map.get(&1.bodies, path, ""))}
  end

  @impl Dav.Web.Store
  def put(path, body, content_type, agent) do
    if exists?(agent, Enum.drop(path, -1)) do
      store(agent, path, body, content_type)
    else
      {:error, :conflict}
    end
  end

  defp store(agent, path, body, content_type) do
    existed? = exists?(agent, path)

    resource = %Resource{
      path: path,
      content_type: content_type,
      content_length: byte_size(body),
      etag: ~s("#{:erlang.phash2(body)}")
    }

    Agent.update(agent, fn state ->
      %{
        state
        | resources: [resource | Enum.reject(state.resources, &(&1.path == path))],
          bodies: Map.put(state.bodies, path, body)
      }
    end)

    {:ok, if(existed?, do: :replaced, else: :created), resource}
  end

  @impl Dav.Web.Store
  def delete(%Resource{path: path}, agent) do
    Agent.update(agent, fn state ->
      %{
        state
        | resources: Enum.reject(state.resources, &(Enum.take(&1.path, length(path)) == path)),
          bodies: Map.reject(state.bodies, fn {p, _b} -> Enum.take(p, length(path)) == path end)
      }
    end)

    :ok
  end

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
    Agent.update(agent, &%{&1 | resources: [resource | &1.resources]})
    {:ok, resource}
  end

  defp inherited(agent, path) do
    parent = Enum.drop(path, -1)

    Agent.get(agent, fn state ->
      case Enum.find(state.resources, &(&1.path == parent)) do
        %Resource{owner: owner} -> owner
        nil -> nil
      end
    end)
  end

  defp exists?(_agent, []), do: true

  defp exists?(agent, path) do
    Agent.get(agent, &Enum.any?(&1.resources, fn r -> r.path == path end))
  end

  @impl Dav.Web.Store
  def properties(%Resource{path: path}, agent) do
    Agent.get(agent, &Map.get(&1.dead, path, %{}))
  end

  # Atomic by construction: the new map is computed in full and only
  # then written, so a refusal leaves the old one untouched.
  @impl Dav.Web.Store
  def patch(%Resource{path: path}, instructions, agent) do
    current = Agent.get(agent, &Map.get(&1.dead, path, %{}))

    updated =
      Enum.reduce(instructions, current, fn
        {:set, name, value}, acc -> Map.put(acc, name, value)
        {:remove, name}, acc -> Map.delete(acc, name)
      end)

    Agent.update(agent, &%{&1 | dead: Map.put(&1.dead, path, updated)})
    :ok
  end

  @impl Dav.Web.Store
  def copy(%Resource{path: from}, to, agent) do
    Agent.update(agent, fn state -> transplant(state, from, to, :keep) end)
    :ok
  end

  @impl Dav.Web.Store
  def move(%Resource{path: from}, to, agent) do
    Agent.update(agent, fn state -> transplant(state, from, to, :drop) end)
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

    Agent.update(agent, &%{&1 | resources: [resource | &1.resources]})
    {:ok, resource}
  end

  defp calendar?(_agent, []), do: false

  defp calendar?(agent, path) do
    Agent.get(agent, fn state ->
      Enum.any?(state.resources, &(&1.path == path and Cal.calendar() in &1.types))
    end)
  end
end
