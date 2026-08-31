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

  @optional_callbacks headers: 3,
                      deleted: 2,
                      properties: 3,
                      action: 4,
                      types: 3,
                      patchable: 3,
                      relocated: 3,
                      removable: 3

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
end
