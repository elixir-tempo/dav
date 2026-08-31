# Apple CalendarServer — behavioural reference sources

Fetched from https://github.com/apple/ccs-calendarserver at commit `13c706b985fb728b9aab42dc0fef85aae21921c3` (master; the repository is archived and no longer moves). Licensed Apache-2.0 — see `LICENSE.txt`, copied from the repository root.

## Why these files are here

The CalDAVTester fixtures under `../conformance/caldavtester/` are the *outputs of this server*: every expected `.ics` body is what CalendarServer produced, incidental behaviour included. Where a fixture's expectation cannot be derived from an RFC — when `Schedule-Tag` changes, how `SEQUENCE` moves on a cancellation, what counts as per-user data — the answer is in this code, verbatim, and reading it beats reverse-engineering the fixtures. The first use: `processScheduleTags` settled that an explicit client change *always* takes a fresh `Schedule-Tag`, where this repo had inferred a shape comparison from too few fixtures.

## What is vendored

* `scheduling/implicit.py` — the implicit-scheduling state machine: what counts as an organiser/attendee change, who gets told.

* `scheduling/icaldiff.py` — the change classifier `implicit.py` consults: which property differences re-invite, which merely update.

* `scheduling/itip.py` — iTIP message generation and application, `SEQUENCE` handling included.

* `scheduling/processing.py` — how a received message is applied to the recipient's copy (auto-processing, attendee refreshes).

* `datafilters/peruserdata.py` — the per-user data model: which properties (`TRANSP`) and components (`VALARM`) belong to one user's view of a shared event.

* `scheduling/sql-processScheduleTags.py` — a 55-line excerpt of `txdav/caldav/datastore/sql.py` (which is 5,547 lines and not worth vendoring whole): the `Schedule-Tag` rules.

Nothing here is executed. These are read the way the RFCs in `../` are read.
