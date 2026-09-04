# Status

Where the CalDAVTester conformance work stands, and how to continue it. Written 2026-09-04, against `eb930fb` plus the availability batch.

`CONFORMANCE.md` explains *what* was built and why each remaining failure is acceptable. This file is the working state: the numbers, the loop, and what to pick up next.

## The position

| | |
| --- | ---: |
| Scenarios | 162 |
| Tests | 5,092 |
| Passing | 4,994 |
| **RFC-required failing** | **0** |
| Apple/interop failing | 58 |
| Incidental, cited | 40 |
| **Unclassified** | **0** |
| Features declared | 49 |

RFC-required has been 0 for the whole drive and is the number that must not move. Unclassified is the queue that has to be empty before a batch closes: a failure nobody has classified is a failure nobody has looked at.

## The loop

Work proceeds in batches. One batch opens one pool of tests — usually by implementing a feature and then declaring it in `test/support/caldavtester/features.ex` — and ends with the corpus measured, the baseline regenerated, the docs updated, and a one-line commit.

**Measure a single scenario while iterating.** Never the corpus; it takes about 3.5 minutes.

```
MIX_ENV=test mix run priv/one.exs timezonestdservice
```

It prints the passing count and every test that did not pass, with the reason the verifier gave.

**Close the batch with one corpus run, not four.** This is the whole point of `Dav.CalDAVTester.Corpus`:

```
DAV_BASELINE=1 mix test
```

That single pass gives the regression check, the per-file drift against the recorded baseline, the classified headline, the README totals, the rewritten baseline, and the unit suite. `DAV_REPORT=1` prints the same report without rewriting the baseline. `priv/baseline.exs` and `priv/conformance.exs` still exist as thin wrappers for when you want one on its own.

The other five gates touch no corpus and take about ten seconds:

```
mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && MIX_ENV=release mix docs --warnings-as-errors
```

A batch is done when the corpus is net-zero-or-better, RFC-required is 0, Unclassified is 0, all six gates are green, and `README.md` plus `CONFORMANCE.md` carry the new numbers.

## What is left

### Pools not yet opened — 20 files, 479 tests

Each is gated shut by a feature this server does not implement. Declaring a feature without building it inflates the denominator and turns the conformance figure into a claim, so the gate stays until the code exists.

| pool | tests | needs |
| --- | ---: | --- |
| `implicitgroup.xml`, `trash-implicitgroup.xml` | 97 | group attendee expansion, `control-api` |
| `partitioning-*.xml` | 48+ | multi-node partitioning |
| `dropbox.xml`, `implicitdropbox.xml` | 66 | legacy dropbox |
| `implicit-traveltime.xml`, `sharing-traveltime.xml` | 60 | travel-time busy |
| `polls.xml` | 28 | `VPOLL` |

**Those counts are upstream's `<test>` elements and they over-count.** Several files comment whole suites out — `availability.xml` was listed at 29 and yielded 7 live tests when it opened. Treat the column as an upper bound, and measure the file before planning around it.

Every remaining standard is now declared. What is left needs either a feature of real size or a deployment this library is not:

* **`implicitgroup`** is the largest at 97, and wants two things — expanding a group attendee into its members, and the `control-api` the suite uses to change directory membership mid-scenario. The second is not a protocol, so a chunk of the file is unreachable without inventing one.

* **`dropbox`** is Apple's pre-managed-attachments model, superseded by the managed attachments this server already implements. Building the legacy alongside is 66 tests for a feature Apple itself replaced.

* **travel time** wants `X-APPLE-TRAVEL-DURATION` folded into busy-time answers — self-contained, and the smallest real feature left.

* **`polls.xml`** is `VPOLL`, a draft that never became an RFC.

* **`partitioning-*`** is a deployment topology rather than a library feature and is probably never worth declaring.

### Three files open but scoring zero — checked, and not worth returning to

`bad-ical.xml`, `bad-json.xml` and `schedulenomore.xml` are not gated and pass nothing, which usually means one early request fails and takes the rest of the file with it. It does not here, and all three are cited as incidental: `Resource/CalDAV/bad-ical/` and `Resource/CalDAV/bad-json/` are empty in the archived upstream, so every request in those files has no body to send, and `schedulenomore.xml` exercises a `SCHEDULE` method that was never standardised and that no server should implement. None is a pool.

### The Apple queue — 58 failing tests across 40 files

All cited in `test/support/caldavtester/classification.exs`. The clusters:

* **Group sharing, 33 tests across 13 `sharing-*` files.** The open tail of the group-sharee model; the largest single cluster left.
* **`trash.xml`, 4 suites.**
* **`implicitschedulechanges.xml`, 4 suites** — properties this server does not name among what a scheduling message changed.
* **`privatecomments.xml`, 5**, **`implicitscenario1.xml`, 4**, **`default-alarms.xml`, 2**, and singletons elsewhere.
* **Room auto-scheduling, 6** — the reference's two-phase delivery, which this engine's single-pass organizer-side answering does not reproduce.

None of these is a defect against an RFC. They are behaviours beyond the specifications where CalendarServer does something this server does not.

## Conventions that are load-bearing

* **`test/support/caldavtester/classification.exs`** assigns every failing test a class and a reason. A new failure with no entry shows up as Unclassified and fails the batch. Keys are `{file, suite}` or `{file, nil}` for a whole file.

* **The feature-count guard** in `test/caldavtester_test.exs` asserts `MapSet.size(declared) < 50`. It is a ceiling, not a target: when it trips, the moment to check is whether the feature just declared is actually built.

* **The baseline is a ratchet.** `test/support/caldavtester/baseline.exs` records passing tests per scenario. A scenario that drops fails the build; one that rises also fails, so the recorded figure is never stale. Regenerate only through `DAV_BASELINE=1 mix test`.

* **Fixture repairs are recorded in `rfc/conformance/caldavtester/FETCHING.md`.** The vendored corpus is an archive with dated and occasionally broken fixtures; every repair to one is written down there with its reason. Repair the fixture, do not weaken the verifier.

* **Verifier ports are faithful to upstream, not to a reasonable reading of it.** Fifteen are ported. Two fidelity bugs found during the timezone work are worth knowing about as a pattern: `**` in a URI means "somewhere new" only before the query string, and repeated query parameters must not be collapsed the way `Plug.Conn.Query` collapses them.

* **The harness is the deployment.** `Dav.CalDAVTester.Runner` routes `/stdtimezones` and `/timezones` to the two timezone plugs and everything else to `Dav.Web.Plug`, because those services are not DAV. New non-DAV surfaces get routed the same way rather than being folded into the DAV plug.

## Recently landed

* **RFC 7953 availability** (`Dav.Cal.Availability`). `availability.xml` in full, 7 tests. A `VAVAILABILITY` kept in `CS:calendar-availability` on the Inbox says which hours its owner would accept a meeting in; the available windows are expanded and subtracted from the query window, and the remainder is reported at the component's `BUSYTYPE` — `BUSY-UNAVAILABLE` by default. `Dav.Cal.FreeBusy` now writes a period the way its own specification's examples do: RFC 5546 busy time as a start and a duration, RFC 7953 unavailable time as two instants. Nothing else in the corpus moved.

* **What a `GET` on a collection does**, in `Dav.Web.Plug` (`directory listing`). 91 tests gained across three files — `collection-redirects.xml`, `directory.xml` and two gated suites of `get.xml`, all passing in full. A collection addressed without its trailing slash redirects to the one it has; a deployment may ask for a listing with `listings: true`; a browser gets that listing ahead of whatever an extension would render; and a collection read carries an `ETag` over the rendering plus a `Last-Modified`, and answers `304`. `c:Dav.Web.Hook.rendered/2` gained `{:error, :forbidden}` for a collection that may be addressed but not enumerated. Nothing else in the corpus moved.

* **jCal** (`Dav.Cal.JCal`) — RFC 7265, calendar data as JSON. 52 tests gained, `json.xml` in full. One syntax is stored, iCalendar, and the JSON is converted at the edges: a codec keyed on RFC 5545's value-type table, plus negotiation on six surfaces (`Accept`, `Prefer: return=representation`, a report's `calendar-data content-type`, an Outbox `POST`, a bulk request, and `CALDAV:calendar-timezone`). Three base seams came out of it — `c:Dav.Web.Hook.taken/4` and `c:Dav.Web.Hook.offered/6` for negotiation, a revising `c:Dav.Web.Hook.patchable/3`, and `Dav.Xml.parse_propfind/1` now returning the attributes a client wrote on the properties it asked for. Nothing else in the corpus moved, which was worth checking: the change touches `PROPFIND`, `PROPPATCH`, `GET`, `PUT` and both reports.

* **Apple's bulk `POST`** (`Dav.Cal.Bulk`), both forms — the simple `VCALENDAR` divided per `UID` and the `MM:multiput` CRUD document — with `MM:bulk-requests`, `X-MobileMe-DAV-Options: return-changed-data` and the ctag `If` condition. 59 tests gained, `bulk.xml` in full. Two seams came out of it: `Dav.Web.Write.document/5` is the write `PUT` performs, now shared rather than reimplemented, and `Dav.Web.Hook.removing/2` and `removal/3` are the delete side of the same thing. One scheduling rule moved with it: `SEQUENCE` rises on a significant organiser change rather than only when a message goes out, which cost nothing elsewhere in the corpus.

* **RFC 7808 time zone service** (`Dav.Cal.TimezoneService`) and **CalendarServer's older query dialect** (`Dav.Cal.TimezoneQuery`), both over one catalogue in `Dav.Cal.Zones`, which reads the same IANA distribution the `tz` dependency compiles against. 87 tests gained. Nine cited failures are all one thing: `calendarDataMatch` compares against `VTIMEZONE` captured from CalendarServer on the 2016 database, including `TZNAME` spellings IANA's data does not carry.

* **RFC 4331 quota** through a `c:Dav.Web.Store.quota/2` callback, so which parts of a tree are bounded stays the store's decision. +50.

* **One corpus run per close-out** (`Dav.CalDAVTester.Corpus`), replacing four. This was a response to the review cost exceeding the work.
