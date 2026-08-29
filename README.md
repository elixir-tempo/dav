# Dav

WebDAV, CalDAV and CardDAV servers as a Plug — the protocol, with storage left to you.

Three protocols in one library because they are one protocol wearing three hats: CalDAV and CardDAV are strict extensions of WebDAV, they extend it through the same mechanism, and a change to the base is a change to all three.

```
HTTP                    RFC 9110/9111/9112
  └── WebDAV            RFC 4918   methods, properties, collections, 207
        └── REPORT      RFC 3253   the extension point everything hangs off
              └── CalDAV      RFC 4791
              └── CardDAV     RFC 6352
```

`REPORT` is worth singling out: it is defined by the *versioning* extensions rather than by WebDAV itself, and every CalDAV and CardDAV query is one. An implementation that omits it cannot host either.

## Status

**The WebDAV base is complete, apart from locking.** Built:

* `Dav.Xml` — namespaced XML both directions: `207 Multi-Status`, `PROPFIND` and `PROPPATCH` parsing, `DAV:error` documents, `DAV:supported-report-set`.
* `Dav.Web.Resource`, `Dav.Web.Store` — an addressable resource, and the storage behaviour.
* `Dav.Web.Properties` — the live properties of RFC 4918 section 15, and which of them are protected.
* `Dav.Web.Plug` — `OPTIONS`, `GET`, `HEAD`, `PUT`, `DELETE`, `MKCOL`, `PROPFIND`, `PROPPATCH`, `COPY`, `MOVE`, and `REPORT` dispatched by qualified name.
* `Dav.Web.Report` — the behaviour CalDAV and CardDAV attach to.

**A store's capabilities decide the server's.** Everything except resolving and listing is an optional callback, so a read-only store yields a read-only server whose `Allow` header omits what it cannot do. Nothing is advertised that would fail.

**There is no locking, and there will not be.** Class 1 only. RFC 4918 permits it, most clients tolerate it, and `LOCK` is a large fraction of the specification for something a read-mostly server does not need. Advertising `DAV: 1, 2` without implementing it would be worse than not advertising it.

Not built: `Dav.Cal` and `Dav.Card`, collection synchronisation (RFC 6578), and ACL (RFC 3744).

## Measured against the conformance suite

Apple's CalDAVTester issues 6,407 real HTTP requests across its 193 scenarios. **5,584 of them (87%) now have a method that answers them.** What remains is `POST` (633 — scheduling and sharing), `MKCALENDAR` (125 — `Dav.Cal`) and `ACL` (64).

That is a measure of surface, not of conformance: the suite tests a full CalDAV *and* CardDAV server including principals, ACL, scheduling and Apple's sharing extension, which is a groupware product rather than a protocol library. See `plans/dav.md` in the repository for where the scope stops and why.

## On parsing XML safely

Request bodies come from unauthenticated clients, so the parser is the attack surface. `Dav.Xml` scans with `allow_entities: false` passed explicitly rather than relying on the default. Measured on OTP 29:

| `:xmerl_scan.string/2` options | External entity |
| --- | --- |
| default | refused |
| `allow_entities: false` | refused |
| `allow_entities: true` | **parsed — local file contents reached the document** |

The default is safe today. It has not always been, which is why it is stated rather than assumed.

## The specifications

Vendored under `rfc/` in the repository: 41 RFCs with their errata, and Apple's CalDAVTester — 226 scenarios describing what real clients expect. Worth reading before writing code, because RFC 4791 carries 24 errata and RFC 5545 carries 39.

## Installation

Not yet published.

## License

Apache-2.0.
