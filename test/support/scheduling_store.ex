defmodule Dav.Test.SchedulingStore do
  @moduledoc """
  A writable store that can also resolve calendar user addresses.

  `Dav.Test.WritableStore` with `c:Dav.Web.Store.principal/2` added, so
  the scheduling tests can exercise the path where an address does
  resolve — and, as importantly, the path where it does not.
  """

  @behaviour Dav.Web.Store

  alias Dav.Test.WritableStore

  def start(resources, addresses) do
    agent = WritableStore.start(resources)
    Agent.update(agent, &Map.put(&1, :addresses, addresses))
    agent
  end

  @impl Dav.Web.Store
  def principal(address, agent) do
    case Agent.get(agent, &get_in(&1, [:addresses, address])) do
      nil -> {:error, :not_found}
      path -> resolve(path, agent)
    end
  end

  @impl Dav.Web.Store
  defdelegate resolve(path, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate children(resource, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate read(resource, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate put(path, body, content_type, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate delete(resource, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate mkcol(path, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate properties(resource, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate patch(resource, changes, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate copy(resource, destination, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate move(resource, destination, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate mkcalendar(path, agent), to: WritableStore
end
