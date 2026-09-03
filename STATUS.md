# Status

Where the CalDAVTester conformance work stands, and how to continue it. Written 2026-09-04, against `47c7ba6` plus the bulk `POST` batch.

`CONFORMANCE.md` explains *what* was built and why each remaining failure is acceptable. This file is the working state: the numbers, the loop, and what to pick up next.

## The position

| | |
| --- | ---: |
| Scenarios | 162 |
| Tests | 4,941 |
| Passing | 4,844 |
| **RFC-required failing** | **0** |
| Apple/interop failing | 58 |
| Incidental, cited | 39 |
| **Unclassified** | **0** |
| Features declared | 46 |

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

### Pools not yet opened — 26 files, 664 tests

Each is gated shut by a feature this server does not implement. Declaring a feature without building it inflates the denominator and turns the conformance figure into a claim, so the gate stays until the code exists.

| pool | tests | needs |
| --- | ---: | --- |
| `collection-redirects.xml` | 72 | directory listing |
| `json.xml` | 65 | jCal |
| `implicitgroup.xml`, `trash-implicitgroup.xml` | 97 | group attendee expansion, `control-api` |
| `partitioning-*.xml` | 48+ | multi-node partitioning |
| `dropbox.xml`, `implicitdropbox.xml` | 66 | legacy dropbox |
| `implicit-traveltime.xml`, `sharing-traveltime.xml` | 60 | travel-time busy |
| `availability.xml` | 29 | `VAVAILABILITY` |
| `polls.xml` | 28 | `VPOLL` |

Best value next is `json` — 65 tests, and the two things it needed are now one: bulk `POST` is built, so what is left is jCal itself, the JSON spelling of iCalendar in RFC 7265, plus `bad-json.xml` beside it. The `jsonPointerMatch` verifier it needs already exists, ported for the timezone work. `collection-redirects` is 72 tests and self-contained. `partitioning-*` is a deployment topology rather than a library feature and is probably never worth declaring.

### Two files open but scoring zero — checked, and not worth returning to

`bad-ical.xml` and `schedulenomore.xml` are not gated and pass nothing, which usually means one early request fails and takes the rest of the file with it. It does not here, and both are already cited as incidental: `Resource/CalDAV/bad-ical/` is empty in the archived upstream, so every request in that file has no body to send, and `schedulenomore.xml` exercises a `SCHEDULE` method that was never standardised and that no server should implement. Neither is a pool.

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

* **Apple's bulk `POST`** (`Dav.Cal.Bulk`), both forms — the simple `VCALENDAR` divided per `UID` and the `MM:multiput` CRUD document — with `MM:bulk-requests`, `X-MobileMe-DAV-Options: return-changed-data` and the ctag `If` condition. 59 tests gained, `bulk.xml` in full. Two seams came out of it: `Dav.Web.Write.document/5` is the write `PUT` performs, now shared rather than reimplemented, and `Dav.Web.Hook.removing/2` and `removal/3` are the delete side of the same thing. One scheduling rule moved with it: `SEQUENCE` rises on a significant organiser change rather than only when a message goes out, which cost nothing elsewhere in the corpus.

* **RFC 7808 time zone service** (`Dav.Cal.TimezoneService`) and **CalendarServer's older query dialect** (`Dav.Cal.TimezoneQuery`), both over one catalogue in `Dav.Cal.Zones`, which reads the same IANA distribution the `tz` dependency compiles against. 87 tests gained. Nine cited failures are all one thing: `calendarDataMatch` compares against `VTIMEZONE` captured from CalendarServer on the 2016 database, including `TZNAME` spellings IANA's data does not carry.

* **RFC 4331 quota** through a `c:Dav.Web.Store.quota/2` callback, so which parts of a tree are bounded stays the store's decision. +50.

* **One corpus run per close-out** (`Dav.CalDAVTester.Corpus`), replacing four. This was a response to the review cost exceeding the work.
