defmodule Dav.Web.Validator do
  @moduledoc """
  A check run before a resource is written, and the third seam.

  `Dav.Web` knows nothing about what it stores, which is why CalDAV
  and CardDAV can attach to it. But both specifications constrain what
  a collection may contain — RFC 4791 section 5.3.2 lists eleven
  preconditions for `PUT` alone — and a server that skips those checks
  corrupts its own collections.

  A validator closes that gap without the base learning what a
  calendar is: `Dav.Cal.Object` is registered against a collection
  type, and the plug consults it before writing.

      forward "/dav", to: Dav.Web.Plug,
        init_opts: [
          store: MyStore,
          validators: [Dav.Cal.Object]
        ]

  ### Failures name a precondition

  A validator returns the qualified name of the rule that was broken,
  and the plug answers `403` with that name in a `DAV:error` document.
  A bare refusal tells a client only that it failed; the precondition
  tells it what to fix.

  """

  alias Dav.Web.Resource
  alias Dav.Xml

  @doc """
  Whether this validator applies to the target collection.

  ### Arguments

  * `collection` is the parent collection being written into, or `nil`
    when it could not be resolved.

  ### Returns

  * `true` when `c:validate/4` should be consulted.

  """
  @callback applies?(collection :: Resource.t() | nil) :: boolean()

  @doc """
  Whether a collection may be created inside this one.

  Optional in spirit and required by the behaviour, because the answer
  is rarely interesting: most collections may hold others. A calendar
  collection may not — RFC 4791 section 4.2 — and nothing in
  `Dav.Web` knows that.

  ### Arguments

  * `collection` is the parent collection.

  ### Returns

  * `:ok`, or `{:error, qname}` naming the precondition.

  """
  @callback permit_collection(collection :: Resource.t() | nil) :: :ok | {:error, Xml.qname()}

  @doc """
  Check a body before it is written.

  ### Arguments

  * `body` is the request body.

  * `collection` is the parent collection.

  * `path` is the path being written, so replacing a resource is not
    mistaken for a conflict with itself.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`; or

  * `{:error, qname}` naming the precondition that failed.

  """
  @callback validate(
              body :: binary(),
              collection :: Resource.t() | nil,
              path :: [String.t()],
              options :: map()
            ) :: :ok | {:error, Xml.qname()}
end
