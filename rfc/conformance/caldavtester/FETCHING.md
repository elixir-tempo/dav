# CalDAVTester — provenance

Vendored complete from https://github.com/apple/ccs-caldavtester at
commit `bed21e5924275552c1561febc8203a9f194cf737` on 2026-08-29. Apache-2.0; see LICENSE.txt.

**Upstream is archived** — frozen in February 2024 and it will not
change again, which is why vendoring it is reasonable rather than lazy,
and why the pinned commit above will not move.

## What is here

* `scripts/` — 193 XML test scenarios (162 CalDAV, 31 CardDAV), holding 6,675 individual tests. Each is a sequence of requests with
  the responses a conformant server must give, which makes the suite a
  better statement of what real clients expect than the RFCs are:
  where an RFC says what is permitted, these say what Apple Calendar
  will actually do.

* `Resource/` — the calendar and contact fixtures the scenarios load.

* `verifiers/` — the response checks the scenarios refer to.

* `src/` — the harness itself: `caldavtest.py` runs a scenario,
  `request.py` models one request and its grabs, `serverinfo.py` the
  substitutions. Vendored because our own runner has to answer the
  same questions — when `end-delete` fires, what `change-uid` scopes,
  what `WAITCOUNT` waits for — and deriving those from the scenarios
  is guesswork where the reference implementation is simply the
  answer.

**The harness itself is not vendored** — `caldavtester.py` and its
`src/` are not here, only the data it reads. Running the suite would
also need a populated `serverinfo.xml`, authentication and provisioned
principals, none of which this library has. The scenarios are used
here as a corpus of what real clients send, not as a test runner.

The fixtures were left out at first, to keep the repository small. That
was a mistake worth recording: **189 of the 193 scenarios reference
them**, and none carry request bodies inline, so without them the
scenarios were not merely un-runnable but largely unreadable. A
scenario that points at `Resource/CardDAV/vpropfinds/1.xml` tells you
nothing if that file is absent.

## One deliberate change from upstream

Four `.gitignore` files have been deleted — `scripts/.gitignore`,
`Resource/.gitignore`, and two empty ones under `Resource/CalDAV/`.
They are upstream's own build hygiene, and the first silently excluded
195 of the vendored files, including every test scenario. Two were
empty and the fourth named a directory the archive does not contain.
Nothing else has been modified.
