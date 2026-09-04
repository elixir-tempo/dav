# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

* Apple's bulk `POST` (`Dav.Cal.Bulk`): a whole `VCALENDAR` divided into one resource per `UID`, or an `MM:multiput` naming writes, updates and deletes at once, answered with a `207` reporting each entry on its own.
* jCal — RFC 7265 (`Dav.Cal.JCal`): calendar data written as JSON, taken on a write and offered on a read wherever a client asks for it. What is stored stays iCalendar.
* `Dav.Web.Write.document/5`, the single-document write `PUT` performs — validators in front, hooks behind — so an extension writing on a client's behalf writes the same way.
* `c:Dav.Web.Hook.taken/4` and `c:Dav.Web.Hook.offered/6`, content negotiation's two halves, so an extension decides which media types a collection accepts and offers.
* A `GET` on a collection: a `301` to the trailing-slash address, an optional listing (`listings: true`), an `ETag` and `Last-Modified` over the rendering, and `304` for a conditional read.
* `Dav.Cal.Availability` — RFC 7953 `VAVAILABILITY`, kept in `CS:calendar-availability` on the Inbox and reported as `FBTYPE=BUSY-UNAVAILABLE` in every busy-time answer.
* `Dav.Cal.Travel` — Apple's `X-APPLE-TRAVEL-DURATION` and `X-APPLE-TRAVEL-RETURN-DURATION` extend a busy period either side of the event.
* Per-user data on a shared calendar covers every `X-` property and subcomponent, not `TRANSP` and `VALARM` alone, so each sharee's own view of one event stays theirs.
* `X-WR-CALNAME` on the rolled-up calendar a `GET` on a calendar collection returns, from its `DAV:displayname`.

### Changed

* `SEQUENCE` now rises whenever an organiser changes what the attendees hold, not only when a scheduling message goes out. An event whose only attendee is its own organiser numbers its revisions.
* `Dav.Xml.parse_propfind/1` returns `{:prop, names, attributes}` rather than `{:prop, names}`, carrying the attributes a client wrote on the properties it asked for.
* `c:Dav.Web.Hook.patchable/3` may return `{:ok, instruction}` to revise a `PROPPATCH` instruction, not only `:ok` or a refusal.
* `c:Dav.Web.Hook.rendered/2` may return `{:error, :forbidden}`, for a collection that is addressable but must not be enumerated.

### Fixed

* Per-user data on a shared calendar is removed with the resource it belongs to, so an object written at a path a deleted one used no longer inherits a stranger's alarms.

## [0.1.0] - 2026-09-02

First release. WebDAV and CalDAV are built; CardDAV is not.

### Highlights

* **WebDAV — RFC 4918, class 1.** `Dav.Web.Plug` serves `OPTIONS`, `GET`, `HEAD`, `PUT`, `DELETE`, `MKCOL`, `PROPFIND`, `PROPPATCH`, `COPY`, `MOVE` and `REPORT`, with `Dav.Web.Store` as the storage behaviour — two required callbacks, everything else optional, and what a store implements decides what the server advertises. There is no locking and there will not be.

* **CalDAV — RFC 4791.** `MKCALENDAR`, the `calendar-query`, `calendar-multiget` and `free-busy-query` reports, the section 9.9 overlap table with recurrence expanded through Tempo, and the extended query grammar (`test="anyof"`, `match-type`).

* **Scheduling — RFC 6638.** Implicit scheduling end to end: invitations on save, replies from attendees, cancellations and reschedules as iTIP, free-busy over the Outbox, auto-accepting resources in all six modes, and the `Schedule-Tag` ledger governing conditional writes.

* **Synchronisation — RFC 6578.** `DAV:sync-collection` and `DAV:sync-token` on calendars, the scheduling Inbox, notification collections and the calendar home.

* **Access control — RFC 3744.** The `ACL` method with grants and denies for href principals and `DAV:authenticated`, first matching ace deciding, a calendar's list inherited by its objects, and per-object lists consulted inside reports and free-busy.

* **Apple extensions.** Calendar sharing, calendar-user proxies, private events (`X-CALENDARSERVER-ACCESS`), managed attachments, recurrence splitting (`POST ?action=split`), extended free-busy, free-busy mask-uid, `CS:getctag`, `/.well-known/caldav`, and the `Brief` header.

* **Conformance.** 4,214 of 4,235 applicable CalDAVTester tests pass, run in-process in CI. None of the failures are against RFC-required behaviour; each is classified and cited in the [conformance record](https://hexdocs.pm/dav/conformance.html).

See the [README](https://hexdocs.pm/dav/readme.html) for what each module does and how a store is wired in.
