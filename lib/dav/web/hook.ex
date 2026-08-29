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

  @optional_callbacks headers: 3, deleted: 2, properties: 3, action: 4

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
          required(:collection) => Resource.t() | nil
        }

  @callback written(change :: change(), options :: map()) :: :ok
end
