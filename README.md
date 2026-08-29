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

**Early, and honest about it.** Built so far:

* `Dav.Xml` — the namespaced XML both directions need. `207 Multi-Status` responses with namespaces collected and declared once, and `PROPFIND` request parsing.
* `Dav.Web.Resource` — an addressable resource, collection or not.
* `Dav.Web.Store` — the storage behaviour.

Not built yet: the Plug and its method dispatch, `PROPFIND` end to end, `REPORT`, and everything in `Dav.Cal` and `Dav.Card`.

## On parsing XML safely

Request bodies come from unauthenticated clients, so the parser is the attack surface. `Dav.Xml` scans with `allow_entities: false` passed explicitly rather than relying on the default. Measured on OTP 29:

| `:xmerl_scan.string/2` options | External entity |
| --- | --- |
| default | refused |
| `allow_entities: false` | refused |
| `allow_entities: true` | **parsed — local file contents reached the document** |

The default is safe today. It has not always been, which is why it is stated rather than assumed.

## The specifications

Vendored under [`rfc/`](rfc/README.md): 41 RFCs with their errata, and Apple's CalDAVTester — 226 scenarios describing what real clients expect. Worth reading before writing code, because RFC 4791 carries 24 errata and RFC 5545 carries 39.

## Installation

Not yet published.

## License

Apache-2.0.
