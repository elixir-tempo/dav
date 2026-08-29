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

`Dav.CalDAVTester.Features` declares what is built, and each entry is a claim checkable against the code — `caldav`, `COPY`/`MOVE`, `regular-collection`, `current-user-principal`, the four RFC 3744 principal reports, `expand-property`, `acl-principal-prop-set`, `implicit-scheduling`, and `shared-calendars`. The list grows only when the capability exists: a feature declared but not built turns a conformance figure into a claim, and it enlarges the denominator honestly rather than flattering the percentage.

Against that declaration the suite puts **2,534 tests**, of which:

| outcome | tests | |
| --- | ---: | --- |
| passed | 1,907 | 75% |
| failed | 575 | 23% |
| skipped | 52 | 2% |

Fourteen verifiers are ported — `statusCode`, `header`, `multistatusItems`, `propfindItems`, `propfindValues`, `dataString`, `dataMatch`, `calendarDataMatch`, `xmlDataMatch`, `xmlElementMatch`, `prepostcondition`, `freeBusy` and `postFreeBusy` — along with the suite's compound directives (`DELETEALL`, `GETNEW`, `WAITCOUNT`, `GETCONTAINS`) and the `grab` elements that carry a value from one response into a later request. A check the harness cannot make is reported skipped, never counted as a pass.

`xmlDataMatch` and `propfindItems`'s value comparison are the places the port is deliberately not literal. Upstream normalises both documents through ElementTree's serialiser and compares the strings; that output cannot be reproduced here, so the comparison is structural — names, attributes, text and sorted children. It is a stricter test of the same thing: two documents differing only in element order compare equal, and two differing in content do not.

What remains is managed attachments, the finer points of iTIP (per-instance cancellation, partstat propagation), the rest of the sharing extension, and the `ACL` method itself. The whole CalDAV suite regardless of declaration is 5,624 tests.

## On sharing

`Dav.Cal.Sharing` implements Apple's `calendarserver.org` extension — the one that lets one person see or edit another's calendar. No RFC defines it, and it is the most widely deployed CalDAV extension there is: without it a server can talk to Apple Calendar but not share with it.

An owner `POST`s a `CS:share` at their calendar; the invitation is recorded there, reported by `CS:invite`, and a **notification** is dropped into the invitee's notification collection. That last step is the one worth insisting on: an invitee has no reason to poll a calendar they cannot yet see, so a share recorded only on the owner's side is one nobody hears about. `read` is the default access when none is named, because granting write by accident is the mistake that cannot be undone.

`POST` is the one method CalDAV overloads, and `Dav.Cal.Post` routes on the *body* — iCalendar is a scheduling message, an XML document is a sharing one. Routing on the target resource would be wrong: a sharing invitation is posted at the calendar being shared, a scheduling message at an Outbox, and a reply at the invitee's home, which is neither.

## On scheduling

`Dav.Cal.Scheduling` is what makes this a calendar server rather than a shared filing cabinet. Storing an event that names attendees delivers the invitation to each of them — into their Inbox as a message, and into their calendar as an event — and an attendee storing their accepted copy sends a reply that updates the organiser's copy. Neither party posts to an Outbox; the scheduling is implicit in the write, which is what RFC 6638 section 3 requires.

Deleting is scheduling too: an organiser removing an event cancels it for the attendees, and an attendee removing their copy declines it. A cancelled event is *marked* `STATUS:CANCELLED` in the attendee's calendar rather than made to vanish — they may have arranged their day around it.

A recurrence set is one scheduling object, not several. A recurring event and its overridden instances share a `UID` across several components, and an attendee may be named on an override alone — invited to one Tuesday but not the series. Treating the first component as the whole event silently drops those people.

`SCHEDULE-AGENT` decides whether this server delivers at all: `CLIENT` means the organiser's own client will send the invitation, and `NONE` that nobody should. Delivering anyway sends a duplicate, or one the organiser deliberately suppressed.

`Schedule-Tag` (RFC 6638 section 8.2) is stored rather than mirrored from the ETag, and changes only when the *scheduling* content does — who is organising, who is invited, and when it happens. An attendee editing their own alarm changes the ETag; a client holding only that would resynchronise the whole event every time anyone touched anything, which is the problem the second validator exists to solve.

An organiser's client sends `PARTSTAT=NEEDS-ACTION` for everyone, because that is what it was given — it has no way to know who accepted. The server does know, and writing the client's view over its own would un-accept every attendee each time the organiser edited anything. RFC 6638 section 3.2.1 says as much: an organiser may not set another participant's `PARTSTAT`. A *significant* change is the exception, and then `NEEDS-ACTION` is the right answer rather than a client's ignorance.

Six details are easy to get wrong and are covered by tests: an organiser who is also an attendee is not sent an invitation; a reply carries only the attendee who replied, not the whole list; an unaccepted invitation is written `TRANSP:TRANSPARENT`, so it does not block the attendee's time; the `VTIMEZONE`s an event refers to travel with it, or the recipient's client cannot place it; and a reply is matched to its occurrence by `RECURRENCE-ID`, so accepting a series and declining one Tuesday stays two different answers.

Every scheduling object is normalised as it is stored. Addresses go through `c:Dav.Web.Store.canonical_address/2` — one person may be `mailto:`, a bare address, or a URN depending on the client, and storing whichever spelling arrived means an attendee's reply stops matching the invitation it answers. The `CN` is rewritten from the principal's own name for the same reason: a client that invents a name for someone who has one would have every other participant see the invention.

The rewrite happens only when it would change something, so an object already in canonical form costs one comparison and no write.

## On time zones

`tz` is a dependency, and the reason is `TZID`. `DTSTART;TZID=America/Los_Angeles:20260615T090000` is 16:00 UTC; reading it as 09:00 UTC moves the event seven hours, which is enough to put it inside or outside the window a client asked about. A *floating* time — no `TZID`, no `Z` — is resolved against the `CALDAV:timezone` in the request or the collection's `CALDAV:calendar-timezone`, as RFC 4791 section 3.1 requires, and an all-day value is midnight in that zone rather than midnight UTC.

The database also decides whether a `VTIMEZONE` definition is required. RFC 7809 lets a client name a well-known zone and omit it; RFC 4791 section 4.1 requires it otherwise. Telling the two apart needs a zone database, and without one the check either refuses valid data or lets a typo through as a reference.

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
