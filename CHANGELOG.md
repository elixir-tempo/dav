# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

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
