defmodule Dav do
  @moduledoc """
  WebDAV, CalDAV and CardDAV as a Plug.

  Three protocols, one library, because they are one protocol wearing
  three hats. CalDAV and CardDAV are both strict extensions of WebDAV,
  they extend it through the same mechanism — the `REPORT` method — and
  a change to the base is a change to all of them. Splitting them into
  separate packages would buy a dependency edge and a lockstep release
  cycle, and nothing else.

  * `Dav.Web` — WebDAV itself. RFC 4918, plus the `REPORT` method from
    RFC 3253 that everything else hangs off.

  * `Dav.Cal` — CalDAV. RFC 4791.

  * `Dav.Card` — CardDAV. RFC 6352.

  ### What this library is not

  It is not storage, and it is not a calendar server. `Dav.Web.Store`
  is a behaviour: resolve a path to a resource, list a collection's
  members. What is behind it — a filesystem, a database, a scheduling
  ledger — is yours, and this library never learns which.

  Nor does it serve HTTP. It hands you a Plug; run it under Bandit or
  anything else, and keep authentication, TLS and rate limiting in the
  pipeline where they belong.

  ### The specifications

  Every RFC this implements is vendored under `rfc/`, with its errata
  and with Apple's CalDAVTester scenarios. That is not ceremony: RFC
  4791 has 24 errata and RFC 5545 has 39, and an implementation
  written from the specification text alone is wrong in ways the text
  appears to endorse.

  """
end
