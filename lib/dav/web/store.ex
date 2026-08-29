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

  @doc """
  Read a resource's body.

  ### Arguments

  * `resource` is the resolved `t:Dav.Web.Resource.t/0`.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, body}`; or

  * `{:error, :not_found}` if it has gone since it was resolved.

  """
  @callback read(resource :: Resource.t(), context()) ::
              {:ok, iodata()} | {:error, :not_found}

  @doc """
  Create or replace a resource.

  ### Arguments

  * `path` is the request path in segments.

  * `body` is the request body.

  * `content_type` is the declared type, or `nil`.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, :created, resource}` when nothing was there; or

  * `{:ok, :replaced, resource}` when something was; or

  * `{:error, :conflict}` when the parent collection does not exist,
    which RFC 4918 requires rather than creating it.

  """
  @callback put(
              path :: [String.t()],
              body :: binary(),
              content_type :: String.t() | nil,
              context()
            ) ::
              {:ok, :created | :replaced, Resource.t()} | {:error, :conflict}

  @doc """
  Remove a resource, and everything under it if it is a collection.

  ### Arguments

  * `resource` is the resolved `t:Dav.Web.Resource.t/0`.

  * `context` is the store's own configuration.

  ### Returns

  * `:ok`.

  """
  @callback delete(resource :: Resource.t(), context()) :: :ok

  @doc """
  Create a collection.

  ### Arguments

  * `path` is the request path in segments.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, resource}`; or

  * `{:error, :exists}` when something is already there; or

  * `{:error, :conflict}` when the parent does not exist.

  """
  @callback mkcol(path :: [String.t()], context()) ::
              {:ok, Resource.t()} | {:error, :exists | :conflict}

  @doc """
  Whether a store implements a capability.

  Everything except `c:resolve/2` and `c:children/2` is optional, so a
  read-only store is a complete store and gets a read-only server —
  with an `Allow` header that says so rather than promising methods
  that will fail.

  ### Arguments

  * `store` is the module.

  * `capability` is `:read`, `:put`, `:delete` or `:mkcol`.

  ### Returns

  * `true` when the store implements it.

  ### Examples

      iex> Dav.Web.Store.supports?(Dav.Web.Store, :put)
      false

  """
  @spec supports?(
          module(),
          :read | :put | :delete | :mkcol | :properties | :patch | :copy | :move | :mkcalendar
        ) :: boolean()
  def supports?(store, capability) do
    Code.ensure_loaded?(store) and function_exported?(store, capability, arity(capability))
  end

  defp arity(:read), do: 2
  defp arity(:put), do: 4
  defp arity(:delete), do: 2
  defp arity(:mkcol), do: 2
  defp arity(:properties), do: 2
  defp arity(:patch), do: 3
  defp arity(:copy), do: 3
  defp arity(:move), do: 3
  defp arity(:mkcalendar), do: 2

  @doc """
  A resource's dead properties.

  *Dead* properties are whatever a client stored with `PROPPATCH` and
  expects back byte for byte. The server does not interpret them, and
  a store that keeps none is a valid store.

  ### Arguments

  * `resource` is the resolved `t:Dav.Web.Resource.t/0`.

  * `context` is the store's own configuration.

  ### Returns

  * A map of `{namespace, local}` to value.

  """
  @callback properties(resource :: Resource.t(), context()) :: %{
              optional({String.t(), String.t()}) => String.t()
            }

  @doc """
  Apply `PROPPATCH` instructions, all of them or none.

  RFC 4918 requires atomicity: *"Instructions MUST either all be
  executed or none executed."* A store that cannot honour that should
  refuse rather than apply a prefix, because a client has no way to
  discover a partial application.

  ### Arguments

  * `resource` is the resolved `t:Dav.Web.Resource.t/0`.

  * `instructions` are `{:set, qname, value}` and `{:remove, qname}`
    **in document order**, which is significant: setting and then
    removing the same property is not the same as the reverse.

  * `context` is the store's own configuration.

  ### Returns

  * `:ok` when every instruction was applied; or

  * `{:error, :forbidden}` when the store refuses one, in which case
    it must have applied none.

  """
  @callback patch(
              resource :: Resource.t(),
              instructions :: [
                {:set, {String.t(), String.t()}, String.t()} | {:remove, {String.t(), String.t()}}
              ],
              context()
            ) :: :ok | {:error, :forbidden}

  @doc """
  Duplicate a resource at another path.

  ### Arguments

  * `source` is the resolved `t:Dav.Web.Resource.t/0`.

  * `destination` is the target path in segments.

  * `context` is the store's own configuration.

  ### Returns

  * `:ok`. Whatever was at the destination is replaced — the plug has
    already checked `Overwrite` before calling.

  """
  @callback copy(source :: Resource.t(), destination :: [String.t()], context()) :: :ok

  @doc """
  Move a resource to another path.

  ### Arguments

  * `source` is the resolved `t:Dav.Web.Resource.t/0`.

  * `destination` is the target path in segments.

  * `context` is the store's own configuration.

  ### Returns

  * `:ok`.

  """
  @callback move(source :: Resource.t(), destination :: [String.t()], context()) :: :ok

  @doc """
  Create a calendar collection.

  Separate from `c:mkcol/2` because a calendar is not merely a
  collection: it must report `CALDAV:calendar` in its resource type,
  and RFC 4791 forbids one inside another.

  ### Arguments

  * `path` is the request path in segments.

  * `context` is the store's own configuration.

  ### Returns

  * `{:ok, resource}` with `CALDAV:calendar` among its types; or

  * `{:error, :exists}`, `{:error, :conflict}` when the parent is
    missing, or `{:error, :forbidden}` when the parent is itself a
    calendar.

  """
  @callback mkcalendar(path :: [String.t()], context()) ::
              {:ok, Resource.t()} | {:error, :exists | :conflict | :forbidden}

  @doc """
  Resolve a calendar user address to that user's collection home.

  Optional. Scheduling needs it: an `ATTENDEE:mailto:bob@example.com`
  in a request means nothing until the store says which resources are
  Bob's. A store without it cannot answer a busy-time request for
  anyone, which `Dav.Cal.Outbox` reports as an unknown calendar user
  rather than as free time — being told someone is free when they were
  never asked about is the one answer a scheduler must not give.

  ### Arguments

  * `address` is a calendar user address, typically `mailto:...`.

  * `context` is the store's own context.

  ### Returns

  * `{:ok, resource}` for the user's home collection; or

  * `{:error, :not_found}` when the address is not hosted here.

  """
  @callback principal(address :: String.t(), context :: term()) ::
              {:ok, Resource.t()} | {:error, :not_found}

  @doc """
  The calendar user addresses of a principal.

  Optional, and the reverse of `c:principal/2`. Implicit scheduling
  needs it: deciding whether a stored event is the organiser's copy or
  an attendee's means comparing the calendar's owner against the
  `ORGANIZER` address, and a principal URL is not an address.

  ### Arguments

  * `principal` is a principal URL.

  * `context` is the store's own context.

  ### Returns

  * `{:ok, addresses}`, typically `mailto:` URLs; or

  * `{:error, :not_found}`.

  """
  @callback addresses(principal :: String.t(), context :: term()) ::
              {:ok, [String.t()]} | {:error, :not_found}

  @doc """
  The canonical form of a calendar user address.

  Optional. One person may be addressed several ways — `mailto:` in
  one client, a URN in another, a bare address in a third — and a
  server that stores whichever spelling arrived cannot tell that two
  ATTENDEE lines name the same person. Normalising on write is what
  makes an attendee's reply match the invitation they were sent.

  ### Arguments

  * `address` is a calendar user address as written.

  * `context` is the store's own context.

  ### Returns

  * `{:ok, canonical}`; or

  * `{:error, :not_found}` for an address this server does not host,
    which is left exactly as the client wrote it.

  """
  @callback canonical_address(address :: String.t(), context :: term()) ::
              {:ok, String.t()} | {:error, :not_found}

  @optional_callbacks read: 2,
                      put: 4,
                      delete: 2,
                      mkcol: 2,
                      properties: 2,
                      patch: 3,
                      copy: 3,
                      move: 3,
                      mkcalendar: 2,
                      principal: 2,
                      addresses: 2,
                      canonical_address: 2
end
