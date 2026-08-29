defmodule Dav.Test.SchedulingStore do
  @moduledoc """
  A writable store that can also resolve calendar user addresses.

  `Dav.Test.WritableStore` with `c:Dav.Web.Store.principal/2` added, so
  the scheduling tests can exercise the path where an address does
  resolve — and, as importantly, the path where it does not.
  """

  @behaviour Dav.Web.Store

  alias Dav.Cal
  alias Dav.Test.WritableStore
  alias Dav.Web.Store

  def start(resources, addresses, dead \\ %{}, canonical \\ %{}) do
    agent = WritableStore.start(resources)

    Agent.update(agent, fn state ->
      %{state | dead: dead}
      |> Map.put(:addresses, addresses)
      |> Map.put(:canonical, canonical)
    end)

    agent
  end

  @impl Dav.Web.Store
  def canonical_address(address, agent) do
    canonical = Agent.get(agent, &Map.get(&1, :canonical, %{}))

    case Map.fetch(canonical, String.downcase(address)) do
      {:ok, found} -> {:ok, found}
      :error -> {:error, :not_found}
    end
  end

  @impl Dav.Web.Store
  def addresses(principal, agent) do
    known = Agent.get(agent, &Map.get(&1, :addresses, %{}))
    homes = Agent.get(agent, & &1.resources)

    owned =
      for %{path: path, owner: ^principal} <- homes, into: MapSet.new(), do: path

    found =
      for {address, home} <- known, MapSet.member?(owned, home), do: address

    if found == [], do: {:error, :not_found}, else: {:ok, found}
  end

  @impl Dav.Web.Store
  def principal(address, agent) do
    known = Agent.get(agent, &Map.get(&1, :addresses, %{}))
    folded = for {spelling, home} <- known, into: %{}, do: {String.downcase(spelling), home}

    # `mailto:` and `MAILTO:` name the same person, and the suite uses
    # both.
    case Map.fetch(folded, String.downcase(address)) do
      {:ok, path} -> resolve(path, agent)
      :error -> {:error, :not_found}
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

  # A store validates its own property values. `schedule-default-
  # calendar-URL` names one of this store's calendars, and whether a
  # given href is one is a question only the store can answer — the
  # library's job is to report the refusal correctly, which it does.
  @impl Dav.Web.Store
  def patch(resource, changes, agent) do
    if Enum.all?(changes, &acceptable?(&1, agent)) do
      WritableStore.patch(resource, changes, agent)
    else
      {:error, :forbidden}
    end
  end

  @default_calendar {"urn:ietf:params:xml:ns:caldav", "schedule-default-calendar-URL"}

  defp acceptable?({:set, @default_calendar, value}, agent), do: calendar?(value, agent)
  defp acceptable?(_change, _agent), do: true

  defp calendar?({:hrefs, [href]}, agent), do: calendar?(href, agent)

  defp calendar?(href, agent) when is_binary(href) and href != "" do
    case resolve(Store.segments(href), agent) do
      {:ok, resource} -> Cal.calendar?(resource)
      _absent -> false
    end
  end

  defp calendar?(_empty_or_unreadable, _agent), do: false

  @impl Dav.Web.Store
  defdelegate copy(resource, destination, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate move(resource, destination, agent), to: WritableStore

  @impl Dav.Web.Store
  defdelegate mkcalendar(path, agent), to: WritableStore
end
