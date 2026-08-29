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

### The denominator is what this server declares

CalDAVTester gates 850 of its own blocks on `<require-feature>`, read against a `serverinfo.xml` describing *the server under test*. Apple's file declares 84 features because Apple's server implements 84; running this server against that list asks it thousands of questions it never claimed to answer, and a server is not non-conformant for lacking a feature it does not advertise.

`Dav.CalDAVTester.Features` declares four: `caldav`, `COPY Method`, `MOVE Method`, `regular-collection`. Each is a claim checkable against the code, and the list grows only when the capability is built — a feature declared but not implemented turns a conformance figure into a claim.

Against that declaration the suite puts **472 tests**, of which:

| outcome | tests | |
| --- | ---: | --- |
| passed | 284 | 60% |
| failed | 180 | 38% |
| skipped | 8 | 2% |

Nine verifiers are ported — `statusCode`, `header`, `multistatusItems`, `propfindItems`, `dataString`, `dataMatch`, `calendarDataMatch`, `xmlElementMatch`, `prepostcondition` and `freeBusy` — along with the suite's compound directives (`DELETEALL`, `GETNEW`, `WAITCOUNT`, `GETCONTAINS`) and the `grab` elements that carry a value from one response into a later request. A check the harness cannot make is reported skipped, never counted as a pass.

For scale, the whole CalDAV suite regardless of declaration is 5,624 tests. Reaching that means declaring and implementing the rest — scheduling (RFC 6638), ACL (RFC 3744), collection sync (RFC 6578), and Apple's sharing and attachment extensions — one feature at a time, driving this figure to zero at each step.

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
