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

## Deliberate changes from upstream

### Stale years in `freeBusy` expectations

Some suites parameterise their fixtures with `$now.year.N:` — which
resolves relative to the current year — while leaving the expected
values as the literal years they were written against. The two agree
on month, day and time and differ only in the year, so those tests
could not pass on any server, at any time after the year they name.

Repaired here, because the intent is unambiguous: `reports.xml`
parameterises the *identical* expectations that `depthreports.xml`
hard-codes, which settles what the numbers were meant to be.

* `scripts/tests/CalDAV/depthreports.xml` — 90 stamps.

* `scripts/tests/CalDAV/depthreportsacl.xml` — 8 stamps.

* `scripts/tests/CalDAV/servertoserverincoming.xml` — 4 stamps.

* `Resource/CalDAV/servertoserver/3.ics` — its `DTSTART` was
  parameterised and its `DTEND` was not, so the `VFREEBUSY` it sends
  runs from next year back to 2006. The `DTEND` now matches.

Worth 8 tests. `rscale.xml`'s literal dates are left alone: they are
calendar-system anchors rather than expectations about now.

### Suites that reuse a UID without saying so

`testsuite.py` explains the mechanism: "Typically we need the calendar
data for a test file to have a common set of UIDs … Occasionally,
within a test file we also need test suites to have unique UIDs. The
`change-uid` attribute can be used to reset the active UIDs for a test
suite."

`implicitbatchrefresh.xml`'s second and third suites need exactly that
and do not declare it. Each stores an event at a *new* path with the
UID the first suite already used, in the same calendar, with no
`end-delete` in between — so the second suite's opening `PUT` cannot
do anything but fail `no-uid-conflict`, taking the rest of the suite
with it. `change-uid='yes'` added to both. Worth 8 tests.

### Expectations written before address normalisation

`implicit/copymove/put-restrictions/2.ics` and `4.ics` are compared against as *expected* output and carry `ATTENDEE:$cuaddr1:` — the `mailto:` form, with no `EMAIL` parameter. The same suite's `implicit/scenario1/simple` sends that form and requires `urn:x-uid:…` with `EMAIL=` back, the server normalising deliberately. Both cannot hold, and the copymove files have no `EMAIL` anywhere, which is what fixtures written before normalisation existed look like.

Rewritten to the canonical form the rest of the suite requires: `;EMAIL=$emailN::$cuaddrurnN:`. `4.ics` is also *sent* by two requests, and sending the canonical form is what every other scheduling suite does. Worth 5 tests. `1.ics`, `5.ics` and `6.ics` are inputs only and are left as written — sending the `mailto:` form is the thing being tested.

### A suite that depends on another file having run

`sharing-unshare.xml` uses `$hosturl2:` in its `Self uninvite error` reply body but never grabs it; `sharing-freebusy.xml` and `managed-attachments-sharing.xml` do. Upstream's substitutions live on the manager and persist across files in a run, so the value leaks in from whichever file ran first — the suite passes or fails on run order. A `<grabelement>` for it added to the test that already fetches the notification, making the file self-contained.

### Four `.gitignore` files

Four `.gitignore` files have been deleted — `scripts/.gitignore`,
`Resource/.gitignore`, and two empty ones under `Resource/CalDAV/`.
They are upstream's own build hygiene, and the first silently excluded
195 of the vendored files, including every test scenario. Two were
empty and the fourth named a directory the archive does not contain.

Nothing else has been modified.
