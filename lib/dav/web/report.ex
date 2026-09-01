defmodule Dav.Web.Report do
  @moduledoc """
  A handler for one `REPORT`, and the seam the extensions attach to.

  `REPORT` is the extension point of the whole DAV family. The method
  says nothing about what is wanted; the root element of the request
  body names the report, and the server dispatches on it. That is how
  CalDAV adds `calendar-query` and CardDAV adds `addressbook-multiget`
  without either needing to change WebDAV.

  It is defined by RFC 3253, the *versioning* extensions, and not by
  RFC 4918 — which is why an implementation reading only the WebDAV
  specification omits it, and why omitting it makes CalDAV impossible.

  ### Implementing one

  A handler is given the resolved resource and the raw request body,
  because each report has its own grammar: a `calendar-query`'s filters
  have nothing in common with a `sync-collection`'s token, and a shared
  parser would serve neither.

  It returns the responses a `207 Multi-Status` is made of, and this
  library writes the XML — so that every report answers in the same
  shape and namespaces are declared in one place.

  Handlers are registered with `Dav.Web.Plug`, which also reports them
  through `DAV:supported-report-set` so a client can discover what
  exists rather than guessing.

  """

  alias Dav.Web.Resource
  alias Dav.Xml

  @typedoc "One resource's part of a `207 Multi-Status`."
  @type response :: {href :: String.t(), [{status :: String.t(), [{Xml.qname(), Xml.value()}]}]}

  @doc """
  Run the report against a resource.

  ### Arguments

  * `resource` is the resolved request target.

  * `body` is the raw request body, for this report's own parser.

  * `depth` is the `Depth` header, already validated as `0`, `1` or
    `:infinity` — most reports ignore it, and `sync-collection` reads
    its scope from `DAV:sync-level` instead.

  * `options` carries the `:store` and its `:context`. Both are passed
    explicitly — a report routinely needs to read a collection's
    members and their bodies, and a callback that cannot reach its
    store is a seam drawn in the wrong place.

  ### Returns

  * `{:ok, responses}` to be written as a `207 Multi-Status`;

  * `{:ok, {:body, content_type, body}}` to be sent as a `200`, for
    the reports that compute one value rather than a fact about each
    resource — `free-busy-query` returns a single iCalendar object;

  * `{:ok, {:multistatus, responses, trailing}}` for a `207` whose
    root element carries children of its own beside the responses —
    `sync-collection` answers with the new `DAV:sync-token` there;

  * `{:error, :malformed}` when the body does not match this report's
    grammar, which becomes a `400`; or

  * `{:error, :forbidden}`, a `403`, when the report cannot run
    against this kind of resource at all; or

  * `{:error, qname}`, also a `403`, naming the precondition the
    request broke — `CALDAV:supported-calendar-data` when a client
    asks for calendar data in a media type this server does not
    return.

  """
  @typedoc "What the plug resolved for this request."
  @type options :: %{
          required(:store) => module(),
          required(:context) => term(),
          optional(atom()) => term()
        }

  @typedoc "A report that answers with one value rather than a multistatus."
  @type body :: {:body, content_type :: String.t(), iodata()}

  @typedoc "A multistatus carrying elements on the root itself."
  @type trailed :: {:multistatus, [response()], [{Xml.qname(), Xml.value()}]}

  @callback run(Resource.t(), body :: binary(), depth :: 0 | 1 | :infinity, options()) ::
              {:ok, [response()] | body() | trailed()}
              | {:error, :malformed | :forbidden | Xml.qname()}
end
