defmodule Dav.Web.Store do
  @moduledoc """
  Where the resources actually are.

  This library implements the protocol and owns no storage. A store
  resolves paths to `t:Dav.Web.Resource.t/0` values and reads their
  bodies; a filesystem, a database table, or a scheduling ledger can
  each be one without knowing anything about XML or HTTP methods.

  That separation is the whole design. It is also what lets `Dav.Cal`
  and `Dav.Card` add calendar and address book behaviour on top without
  the base needing to know what a calendar is.

  ### Implementing one

  Two callbacks are required. `c:resolve/2` turns a path into a
  resource or reports that there is nothing there; `c:children/2` lists
  a collection's members, and is only ever called on a resource whose
  `collection?` is true.

  A store is handed the options given to `Dav.Web.Plug`, so per-request
  context — the authenticated principal, a tenant, a repo — travels
  through them rather than through process state.

  """

  alias Dav.Web.Resource

  @typedoc "Whatever the store needs to answer a request, from the plug's options."
  @type context :: term()

  @doc """
  Resolve a path to a resource.

  ### Arguments

  * `path` is the request path split into segments, already decoded,
    with no empty segments. The root collection is `[]`.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, resource}`; or

  * `{:error, :not_found}` when nothing is there.

  """
  @callback resolve(path :: [String.t()], context()) ::
              {:ok, Resource.t()} | {:error, :not_found}

  @doc """
  The immediate members of a collection.

  Only called on a resource whose `collection?` is true, and only one
  level deep — `Depth: infinity` is walked by the caller, so a store
  never has to recurse.

  ### Arguments

  * `collection` is the resolved `t:Dav.Web.Resource.t/0`.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, resources}`, which may be empty.

  """
  @callback children(collection :: Resource.t(), context()) :: {:ok, [Resource.t()]}

  @doc """
  Split a request path into the segments a store is given.

  Empty segments are dropped, so a trailing slash makes no difference —
  which matters because clients are inconsistent about sending one for
  collections.

  ### Arguments

  * `path` is a request path.

  ### Returns

  * A list of decoded segments, empty at the root.

  ### Examples

      iex> Dav.Web.Store.segments("/calendars/kim/")
      ["calendars", "kim"]

      iex> Dav.Web.Store.segments("/")
      []

      iex> Dav.Web.Store.segments("/calendars/my%20week")
      ["calendars", "my week"]

  """
  @spec segments(String.t()) :: [String.t()]
  def segments(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&URI.decode/1)
  end
end
