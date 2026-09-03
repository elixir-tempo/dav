defmodule Dav.Web.Write do
  @moduledoc """
  Storing one document the way `PUT` does.

  `PUT` is not `c:Dav.Web.Store.put/4`. In front of the store sit the
  validators that say whether the document may be stored at all, and
  behind it the hooks that run *because* it was — RFC 6638's
  invitations among them. A write that skips either stored bytes and
  told nobody.

  Extensions write on a client's behalf too. Apple's bulk `POST`
  stores several documents from one request, and each of them has to
  be the write a `PUT` would have been: the same
  `CALDAV:no-uid-conflict` refusal, the same invitations, the same
  rewriting by the hooks. Reimplementing that inside the extension
  works until the two drift, and the first symptom is an invitation
  nobody received.

  So the pipeline lives here, and `Dav.Web.Plug` uses it for `PUT`
  exactly as an extension uses it for anything else.

  ### What is deliberately not here

  The conditional headers. `If-Match` and `If-Schedule-Tag-Match` are
  questions about *the request*, and a caller storing several
  documents at once asks them its own way — Apple's bulk `POST`
  carries a separate `MM:if-match` per resource. Deciding whether a
  write may proceed stays with the caller; performing it correctly is
  what this module is for.

  """

  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store

  @doc """
  Store one document, running the validators before and the hooks after.

  ### Arguments

  * `path` is the resource's path segments.

  * `body` is the document to store.

  * `content_type` is the media type as the server states it, or `nil`.

  * `options` carries `:store`, `:context`, `:validators` and
    `:hooks`.

  ### Options

  * `:merge` — whether the caller asked the server to reconcile rather
    than replace, which RFC 6638 section 3.2.10 signals with
    `If-Schedule-Tag-Match`. Defaults to `false`.

  ### Returns

  * `{:ok, :created, resource}` when nothing was there, or `{:ok,
    :replaced, resource}` when something was. Either way the resource
    is the one the store holds *after* the hooks have finished with
    it, not the one the write returned.

  * `{:error, reason}` from whatever refused first: `{:error,
    {namespace, local}}` for a named precondition, `{:error,
    :collection}` for a `PUT` over a collection, `{:error, :conflict}`
    for a missing parent, `{:error, :unsupported}` for a store that
    does not write.

  ### Examples

      iex> Dav.Web.Write.document(["c", "1.ics"], "x", "text/calendar", %{store: Dav.Web.Store})
      {:error, :unsupported}

  """
  @spec document([String.t()], binary(), String.t() | nil, map(), keyword()) ::
          {:ok, :created | :replaced, Resource.t()} | {:error, term()}
  def document(path, body, content_type, options, write_options \\ []) do
    with :ok <- capable(options, :put),
         :ok <- writable(path, options),
         :ok <- Hook.creation(path, :document, options),
         collection = parent(path, options),
         :ok <- validated(body, collection, path, options, content_type),
         previous = held(path, options),
         {:ok, outcome, resource} <- options.store.put(path, body, content_type, options.context) do
      change = %{
        resource: resource,
        body: body,
        previous: previous,
        collection: collection,
        merge: Keyword.get(write_options, :merge, false)
      }

      Hook.saving(change, options)

      {:ok, outcome, settled(resource, path, options)}
    end
  end

  @doc """
  Run the validators that apply to the collection being written into.

  What a collection may contain is the collection's business, not the
  base server's: `Dav.Cal.Object` enforces RFC 4791's restrictions on
  calendar collections without `Dav.Web` learning what a calendar is.

  ### Arguments

  * `body` is the document being stored.

  * `collection` is the collection it is going into, or `nil`.

  * `path` is where it is going.

  * `options` carries `:validators`, and whatever else they need.

  * `content_type` is the media type, which reaches the validators as
    `:content_type`.

  ### Returns

  * `:ok`, or the first refusal a validator gave.

  ### Examples

      iex> Dav.Web.Write.validated("x", nil, ["c", "1.ics"], %{validators: []}, "text/calendar")
      :ok

  """
  @spec validated(binary(), Resource.t() | nil, [String.t()], map(), String.t() | nil) ::
          :ok | {:error, term()}
  def validated(body, collection, path, options, content_type) do
    options = Map.put(options, :content_type, content_type)

    options
    |> Map.get(:validators, [])
    |> Enum.filter(& &1.applies?(collection))
    |> Enum.reduce_while(:ok, fn validator, _outcome ->
      case validator.validate(body, collection, path, options) do
        :ok -> {:cont, :ok}
        failure -> {:halt, failure}
      end
    end)
  end

  @doc """
  What a resource holds, read before a write replaces it.

  A hook that must tell a significant change from a trivial one has no
  other way to see what the resource used to hold.

  ### Arguments

  * `resource` is the resource to read.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The body as a binary, or `nil` when there is nothing to read —
    including when the store does not read at all.

  ### Examples

      iex> Dav.Web.Write.contents(%Dav.Web.Resource{path: ["c"]}, %{store: Dav.Web.Store})
      nil

  """
  @spec contents(Resource.t(), map()) :: binary() | nil
  def contents(resource, %{store: store} = options) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(resource, options.context) do
      IO.iodata_to_binary(data)
    else
      _unreadable -> nil
    end
  end

  # A `PUT` over a collection would have to say what became of its
  # members, and RFC 4918 section 9.7.2 leaves that undefined.
  defp writable(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, %Resource{collection?: true}} -> {:error, :collection}
      _absent_or_document -> :ok
    end
  end

  defp capable(%{store: store}, capability) do
    if Store.supports?(store, capability), do: :ok, else: {:error, :unsupported}
  end

  defp parent(path, %{store: store, context: context}) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, resource} -> resource
      _absent -> nil
    end
  end

  defp held(path, %{store: store, context: context} = options) do
    case store.resolve(path, context) do
      {:ok, resource} -> contents(resource, options)
      _absent -> nil
    end
  end

  # What the store holds once the hooks have finished with it. They
  # may rewrite what was just written — implicit scheduling stamps its
  # own parameters into the organiser's copy — so the resource handed
  # back by the write describes a version that no longer exists.
  # Reporting its `ETag` gives the client a validator that is already
  # stale, and their next conditional request is refused for a change
  # the server made itself.
  defp settled(resource, path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, %Resource{} = current} -> current
      _gone -> resource
    end
  end
end
