defmodule Dav.Test.MemoryStore do
  @moduledoc """
  A store held in a map, for exercising the protocol without a disk.

  Also the reference implementation of `Dav.Web.Store`: if this needs
  to know anything about XML or HTTP, the behaviour is wrong.
  """

  @behaviour Dav.Web.Store

  alias Dav.Web.Resource

  @impl Dav.Web.Store
  def resolve(path, resources) do
    case Enum.find(resources, &(&1.path == path)) do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  @impl Dav.Web.Store
  def children(%Resource{path: path}, resources) do
    depth = length(path) + 1

    {:ok,
     Enum.filter(resources, fn resource ->
       length(resource.path) == depth and Enum.take(resource.path, length(path)) == path
     end)}
  end
end
