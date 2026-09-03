defmodule Dav.Web.Hook do
  @moduledoc """
  Something a collection does when it is written to.

  The fourth seam, alongside `Dav.Web.Method`, `Dav.Web.Report` and
  `Dav.Web.Validator`. A validator says whether a write may happen; a
  hook is what happens *because* it did.

  CalDAV needs exactly one, and it is not optional: RFC 6638 section 3
  requires that storing an event with attendees delivers invitations
  to them. Without it a client's calendar shows an organised meeting
  that nobody was ever told about, which is worse than refusing the
  write — the organiser believes the invitations went out.

      forward "/dav", to: Dav.Web.Plug,
        init_opts: [
          store: MyStore,
          hooks: [Dav.Cal.Scheduling]
        ]

  ### Hooks do not change the response

  A hook runs after the resource is stored and cannot fail the
  request. Delivery to one attendee failing is not a reason to refuse
  an organiser's own write, and RFC 6638 records such failures in the
  stored object's `SCHEDULE-STATUS` rather than in the status line.

  """

  alias Dav.Web.Resource

  @doc """
  Whether this hook applies to the collection written into.

  ### Arguments

  * `collection` is the parent collection, or `nil`.

  ### Returns

  * `true` when `c:written/2` should run.

  """
  @callback applies?(collection :: Resource.t() | nil) :: boolean()

  @doc """
  Headers this hook contributes to a response about a resource.

  Optional. `Schedule-Tag` (RFC 6638 section 8.2) is the reason it
  exists: a scheduling object needs a second validator alongside its
  ETag, because an attendee changing their own `PARTSTAT` changes the
  resource without changing the scheduling content — a client that
  only had an ETag would resynchronise the whole event every time
  somebody accepted.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A list of `{name, value}` header pairs, possibly empty.

  """
  @callback headers(
              resource :: Resource.t(),
              collection :: Resource.t() | nil,
              options :: map()
            ) :: [{String.t(), String.t()}]

  @doc """
  React to a resource having been removed.

  Optional. Deleting a scheduling object is itself a scheduling
  operation: an organiser removing an event cancels it for everyone,
  and an attendee removing their copy declines. A server that treats
  DELETE as mere storage leaves five people holding an invitation to a
  meeting that no longer exists.

  ### Arguments

  * `change` is the `t:change/0`, whose `:body` is what the resource
    held, read before the removal — afterwards there is nothing left
    to read.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`.

  """
  @callback deleted(change :: change(), options :: map()) :: :ok

  @doc """
  Properties this hook contributes to a resource.

  Optional. Some properties are neither stored nor derivable from the
  resource record: `CALDAV:schedule-tag` depends on whether the
  object's *content* is a scheduling message, which only the extension
  that understands calendars can say. Computing it in the base would
  put knowledge of CalDAV back into `Dav.Web`, which is what the seams
  exist to prevent.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A list of `{qname, value}` pairs, possibly empty.

  """
  @callback properties(
              resource :: Resource.t(),
              collection :: Resource.t() | nil,
              options :: map()
            ) :: [{Dav.Xml.qname(), Dav.Xml.value()}]

  @doc """
  Handle a request carrying an `action` query parameter.

  Optional. Apple's CalDAV extensions address several operations this
  way — `?action=share` binds a calendar into the caller's own home —
  rather than by inventing a method for each. The parameter names the
  operation, so the hook that recognises it answers and the rest
  decline.

  ### Arguments

  * `action` is the value of the `action` query parameter.

  * `conn` is the request.

  * `resource` is the resource addressed by the request path.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `{:ok, conn}` when the hook handled the request and has sent a
    response.

  * `:unhandled` when it does not recognise the action, leaving the
    request to be dispatched as usual.

  """
  @callback action(
              action :: String.t(),
              conn :: Plug.Conn.t(),
              resource :: Resource.t(),
              options :: map()
            ) :: {:ok, Plug.Conn.t()} | :unhandled

  @doc """
  Resource types this hook adds to a resource.

  Optional. `DAV:resourcetype` is protected — a client may not tell
  the server what a resource *is* — but an extension may: a calendar
  shared into someone else's home is still a calendar, and also a
  `CS:shared` one, and only the extension that implemented sharing
  knows that.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is its parent collection, or `nil`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The qualified names to add. They are added to whatever the store
    already reports rather than replacing it.

  """
  @callback types(
              resource :: Resource.t(),
              collection :: Resource.t() | nil,
              options :: map()
            ) :: [Dav.Xml.qname()]

  @doc """
  Whether a property instruction may be applied to a resource.

  Optional. Most stored properties are the client's to shape, but an
  extension may give one semantics the server must defend — an href
  set that must name real collections, a property that may be
  replaced but never removed. The base server knows nothing of those
  meanings, so it asks.

  ### Arguments

  * `resource` is the resource being patched.

  * `instruction` is one parsed instruction, `{:set, qname, value}`
    or `{:remove, qname}`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok` when the instruction is acceptable — including when the
    hook has no opinion about the property.

  * `{:error, qname}` naming the refused property.

  """
  @callback patchable(
              resource :: Resource.t(),
              instruction :: {:set, Dav.Xml.qname(), term()} | {:remove, Dav.Xml.qname()},
              options :: map()
            ) :: :ok | {:error, Dav.Xml.qname()}

  @doc """
  A resource has moved to a new address.

  Optional. Anything an extension keeps that points at the old
  address — a default-calendar href, say — is the extension's to
  repair, and only it knows what it stored.

  ### Arguments

  * `source` is the path the resource was moved from.

  * `destination` is the path it now lives at.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, always.

  """
  @callback relocated(
              source :: [String.t()],
              destination :: [String.t()],
              options :: map()
            ) :: :ok

  @doc """
  Whether a resource may be removed by the requesting principal.

  Optional. The base server treats write access as write access; an
  extension may know better — a sharee with write access to a
  calendar may edit their own view of an organiser's event, but
  removing it cancels a meeting that was never theirs to cancel.

  ### Arguments

  * `resource` is the resource the request asks to delete.

  * `collection` is its parent collection, or `nil`.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok` when the hook has no objection.

  * `{:error, {namespace, name}}` naming the precondition that
    refuses the removal.

  """
  @callback removable(
              resource :: Resource.t(),
              collection :: Resource.t() | nil,
              options :: map()
            ) :: :ok | {:error, {String.t(), String.t()}}

  @doc """
  Properties a resource inherits when it states none of its own.

  Optional. A stored value always wins over an inherited one — this
  is the floor under a resource's dead properties, not a ceiling. A
  calendar shared into somebody's home shows the sharer's
  description and name until the sharee sets their own; only the
  extension that implemented sharing knows where to look.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is its parent collection, or `nil`.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The inherited properties, as `{qname, value}` pairs.

  """
  @callback inherited(
              resource :: Resource.t(),
              collection :: Resource.t() | nil,
              options :: map()
            ) :: [{Dav.Xml.qname(), Dav.Xml.value()}]

  @doc """
  Whether a resource may be read at all.

  Optional. Reading is open by default; an extension that keeps
  private material — managed attachments live under their owner's
  home — refuses everyone else here, and the server answers `403`.

  ### Arguments

  * `resource` is the resolved resource.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok`, or `{:error, :forbidden}`.

  """
  @callback readable(resource :: Resource.t(), options :: map()) ::
              :ok | {:error, :forbidden}

  @doc """
  Whether a client may create a resource at this path.

  Consulted before `PUT` stores a new document and before `MKCOL` or
  `MKCALENDAR` makes a collection. An extension that owns part of the
  tree — an attachment area the server alone writes into — refuses the
  creation here.

  ### Arguments

  * `path` is where the client is trying to create.

  * `kind` is what it is trying to create — `:document`, `:collection`
    or `:calendar`.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok`, `{:error, :forbidden}` for a `403`, or
    `{:error, :method_not_allowed}` for a `405`.

  """
  @callback creatable(
              path :: [String.t()],
              kind :: :document | :collection | :calendar,
              options :: map()
            ) :: :ok | {:error, :forbidden} | {:error, :method_not_allowed}

  @doc """
  Present a resource's body to the caller.

  Consulted wherever calendar data is handed out — `GET`, the
  reports, synchronisation. An extension that keeps part of a body
  from some readers filters it here, or refuses the read outright.

  ### Arguments

  * `resource` is the resolved resource.

  * `body` is the stored body, possibly already filtered by an
    earlier hook.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `{:ok, body}` — as given or filtered — or `{:error, :forbidden}`.

  """
  @callback disclosed(resource :: Resource.t(), body :: binary(), options :: map()) ::
              {:ok, binary()} | {:error, :forbidden}

  @doc """
  Run every hook's `c:disclosed/3` over a body.

  ### Arguments

  * `resource` is the resolved resource.

  * `body` is the stored body.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `{:ok, body}` after every hook had its say, or the first
    `{:error, :forbidden}`.

  """
  @spec disclosure(Resource.t(), binary(), map()) :: {:ok, binary()} | {:error, :forbidden}
  def disclosure(resource, body, options) do
    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :disclosed, 3)))
    |> Enum.reduce_while({:ok, body}, fn hook, {:ok, held} ->
      case hook.disclosed(resource, held, options) do
        {:ok, presented} -> {:cont, {:ok, presented}}
        refusal -> {:halt, refusal}
      end
    end)
  end

  @doc """
  Render a collection as a document of its own, for `GET`.

  RFC 4918 leaves `GET` on a collection to the server. An extension
  that can present one — a calendar rolled up into a single iCalendar
  object, say — answers here; every other collection is refused with
  `405` as before.

  ### Arguments

  * `collection` is the resolved collection.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `{:ok, content_type, body}`, or `:skip` when this hook does not
    render this collection.

  """
  @callback rendered(collection :: Resource.t(), options :: map()) ::
              {:ok, String.t(), binary()} | :skip

  @doc """
  The first rendering any hook offers for a collection.

  ### Arguments

  * `collection` is the resolved collection.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `{:ok, content_type, body}` from the first hook that renders it,
    or `:skip`.

  """
  @spec rendering(Resource.t(), map()) :: {:ok, String.t(), binary()} | :skip
  def rendering(collection, options) do
    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :rendered, 2)))
    |> Enum.find_value(:skip, fn hook ->
      case hook.rendered(collection, options) do
        {:ok, type, body} -> {:ok, type, body}
        :skip -> nil
      end
    end)
  end

  @optional_callbacks headers: 3,
                      deleted: 2,
                      properties: 3,
                      action: 4,
                      types: 3,
                      patchable: 3,
                      relocated: 3,
                      removable: 3,
                      inherited: 3,
                      readable: 2,
                      creatable: 3,
                      disclosed: 3,
                      rendered: 2,
                      hidden?: 2

  @doc """
  Ask every hook whether a client may create a resource at this path.

  ### Arguments

  * `path` is where the client is trying to create.

  * `kind` is what it is trying to create — `:document`, `:collection`
    or `:calendar`.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `:ok` when every hook allows it, otherwise the first refusal.

  """
  @spec creation(path :: [String.t()], kind :: atom(), options :: map()) ::
          :ok | {:error, :forbidden} | {:error, :method_not_allowed}
  def creation(path, kind, options) do
    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :creatable, 3)))
    |> Enum.find_value(:ok, fn hook ->
      case hook.creatable(path, kind, options) do
        :ok -> nil
        refusal -> refusal
      end
    end)
  end

  @doc """
  React to a resource having been written.

  ### Arguments

  * `change` is the `t:change/0`: what was stored, what was written to
    it, what it replaced, and the collection it went into. The
    collection matters as much as the resource — it is what carries
    whose calendar this is.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`. A hook cannot fail the request that triggered it.

  """
  @typedoc """
  What changed, and what it replaced.

  Passed as one value rather than a growing argument list, because a
  hook's needs grow: iTIP has to know the *previous* body to tell a
  significant change (which bumps `SEQUENCE` and re-invites everyone)
  from an insignificant one.
  """
  @type change :: %{
          required(:resource) => Resource.t(),
          required(:body) => binary(),
          required(:previous) => binary() | nil,
          required(:collection) => Resource.t() | nil,
          optional(:properties) => %{optional(term()) => term()},
          optional(:merge) => boolean()
        }

  @callback written(change :: change(), options :: map()) :: :ok

  @doc """
  Whether a resource is an extension's own working area, and so not
  part of what a client is shown.

  Optional. A collection an extension keeps for its own purposes — the
  trash a deleted event waits in — is a real resource with real
  members, but listing it in a `PROPFIND` or reporting its members as
  changes would show a client a place it did not put anything and
  cannot use.

  ### Arguments

  * `resource` is the member being considered.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `true` to leave it out of listings and change reports.

  """
  @callback hidden?(resource :: Resource.t(), options :: map()) :: boolean()

  @doc """
  Whether any hook conceals this resource.

  ### Arguments

  * `resource` is the member being considered.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `true` when some hook claims it as its own working area.

  """
  @spec concealed?(Resource.t(), map()) :: boolean()
  def concealed?(resource, options) do
    options
    |> Map.get(:hooks, [])
    |> Enum.any?(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :hidden?, 2) and
          &1.hidden?(resource, options))
    )
  end

  @doc """
  Tell every hook that applies about a write.

  The fan-out `Dav.Web.Plug` performs after a `PUT`, shared so that an
  extension writing calendar data of its own — restoring a trashed
  object, say — announces it the same way rather than announcing it
  differently.

  ### Arguments

  * `change` is the write, as `t:change/0`.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `:ok`.

  """
  @spec saving(change(), map()) :: :ok
  def saving(%{collection: collection} = change, options) do
    for hook <- Map.get(options, :hooks, []), hook.applies?(collection) do
      hook.written(change, options)
    end

    :ok
  end

  @doc """
  Tell the hooks a resource has been removed.

  The counterpart to `saving/2`, and the reason `DELETE` is not merely
  storage: an organiser removing an event cancels it for everyone.
  Anything that removes a resource — `DELETE`, a bulk `POST` carrying
  `MM:delete` — owes the hooks this call, or the attendees keep an
  invitation to a meeting that no longer exists.

  ### Arguments

  * `change` is the `t:change/0`, whose `:body` is what the resource
    held, read before the removal, and whose `:collection` is named
    rather than looked up: by the time a member of a deleted calendar
    is reported, the calendar it belonged to is gone, and a hook asked
    whether it applies to `nil` says no.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `:ok`.

  """
  @spec removing(change(), map()) :: :ok
  def removing(%{resource: resource, collection: collection} = change, options) do
    for hook <- Map.get(options, :hooks, []),
        concerns?(hook, resource, collection),
        exports?(hook, :deleted, 2),
        do: hook.deleted(change, options)

    :ok
  end

  @doc """
  Ask the hooks whether a resource may be removed.

  An extension may know a removal is not the requester's to make — a
  sharee deleting an organiser's meeting — where plain access control
  sees only write permission.

  ### Arguments

  * `resource` is what is about to be removed.

  * `collection` is the collection holding it, or `nil`.

  * `options` carries `:hooks` along with what the callbacks need.

  ### Returns

  * `:ok` when every hook allows it, otherwise the first refusal.

  """
  @spec removal(Resource.t(), Resource.t() | nil, map()) :: :ok | {:error, term()}
  def removal(resource, collection, options) do
    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&exports?(&1, :removable, 3))
    |> Enum.find_value(:ok, fn hook ->
      case hook.removable(resource, collection, options) do
        :ok -> nil
        {:error, _failed} = refusal -> refusal
      end
    end)
  end

  # A hook hears about a deletion when it applies to the collection the
  # resource was in — and, when a collection is itself deleted, when it
  # applies to *that* collection. Deleting a shared calendar has to
  # withdraw its invitations, and the calendar's parent is a plain home
  # that no sharing hook claims.
  defp concerns?(hook, %Resource{collection?: true} = resource, collection) do
    hook.applies?(collection) or hook.applies?(resource)
  end

  defp concerns?(hook, _resource, collection), do: hook.applies?(collection)

  # `function_exported?/3` answers for *loaded* modules only, and a
  # request served before anything else touched an extension would
  # silently skip its callbacks. Loading is idempotent and cheap.
  defp exports?(hook, name, arity) do
    Code.ensure_loaded?(hook) and function_exported?(hook, name, arity)
  end
end
