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

`Dav.Cal` — CalDAV, RFC 4791 — attaches through those two seams without the base knowing what a calendar is:

* `MKCALENDAR` as a `Dav.Web.Method`.
* `calendar-query`, `calendar-multiget` and `free-busy-query` as `Dav.Web.Report`s.
* `Dav.Cal.TimeRange` — the five-row overlap table of RFC 4791 section 9.9, with recurrence expanded through Tempo.

`Dav.Cal.Schedule` begins CalDAV scheduling — RFC 6638, which is Standards Track and **updates RFC 4791**, so it is a requirement rather than an extension. In place so far: the `CALDAV:schedule-inbox` and `CALDAV:schedule-outbox` collection types, the `CALDAV:schedule-response` document, and `POST` on a scheduling Outbox answering a busy-time request — one `CALDAV:request-status` per recipient, so an organiser asking about five people learns which of them could not be answered for.

Not built yet: implicit scheduling on `PUT`, iTIP delivery to Inboxes, `Dav.Card`, collection synchronisation (RFC 6578), and ACL (RFC 3744).

## Measured against the conformance suite

Apple's CalDAVTester is 193 scenario files holding 6,675 tests — the requests real clients make, with the responses a conformant server must give. Upstream drives them from Python over HTTP against a provisioned server. `Dav.CalDAVTester` runs the same files in Elixir, in-process through `Plug.Test`, so the measurement runs in CI beside everything else and needs no Python, no socket and no account database.

Of the 5,624 CalDAV tests it attempts:

| outcome | tests | |
| --- | ---: | --- |
| passed | 1,963 | 35% |
| failed | 2,803 | 50% |
| skipped | 858 | 15% |

Getting there meant implementing the suite's own compound directives — `DELETEALL`, `GETNEW`, `WAITCOUNT`, `WAITDELETEALL`, `GETCONTAINS` and the rest — which are the harness's, not the server's, and the `grab` elements that carry a value out of one response and into a later request. Every `WAIT` collapses to a single check, because this server is called synchronously in-process: there is no other party to wait for.

Nine verifiers are ported: `statusCode`, `header`, `multistatusItems`, `propfindItems`, `dataString`, `dataMatch`, `calendarDataMatch`, `xmlElementMatch` and `prepostcondition`. `calendarDataMatch` compares iCalendar structurally after the filters `serverinfo.xml` prescribes, since a server must stamp its own `DTSTAMP` and `PRODID` and may fold and order differently.

**A check this harness cannot make is skipped, never counted as a pass.**

The remaining failures are the work, not the boundary. They divide as: scheduling 1,215 (RFC 6638), core CalDAV 575 (RFC 4791 defects), Apple sharing 312, ACL 216 (RFC 3744), collection sync 113 (RFC 6578), managed attachments 65. Full conformance is the objective, and Apple's extensions count toward it — Apple Calendar is the client most CalDAV servers actually serve, and this suite is Apple's.

For comparison, the weaker measure this replaces: 5,709 of the suite's 6,407 requests (89%) have a method that answers them at all. That counts surface, not conformance, and the two numbers should not be confused.

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
