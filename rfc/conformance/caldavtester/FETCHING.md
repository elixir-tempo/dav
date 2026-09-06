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

**The harness is vendored in part.** `src/` holds the files our own
runner had to answer the same questions as; the driver and the pieces
it needs to *run* are not here. That gap is now worth closing — see
below — because `Dav.CalDAVTester.Endpoint` serves the deployment over
real HTTP, which is the thing that was missing when the decision was
first made.

## Running the real harness against this server

`test/support/caldavtester/endpoint.ex` provisions the deployment and
serves it with Bandit, authenticating the accounts the scenarios use:

    MIX_ENV=test mix run --no-halt priv/serve.exs 8008

That half is done and answers `401` with a challenge, and `207` to an
authenticated `PROPFIND`. What the *client* half still needs, all from
the same pinned commit:

* `testcaldav.py` — the driver. Note the name: it is not
  `caldavtester.py`, which is why an earlier note here called it that
  and a fetch for it answers `404`.

* Nine files missing from `src/`: `__init__.py`, `httpshandler.py`,
  `jsonPointer.py`, `xmlDefs.py`, and `observers/` (`__init__.py`,
  `base.py`, `jsondump.py`, `loadfiles.py`, `log.py`, `trace.py`).
  `src/unittest/` is the harness's own tests and is not needed.

* **`pycalendar`** — Apple's iCalendar library, from
  `github.com/apple/ccs-pycalendar`, which `requirements.txt` names.
  Five of the vendored verifiers import it (`calendarDataMatch`,
  `freeBusy`, `postFreeBusy`, `addressDataMatch`, `xmlElementMatch`),
  so it is not optional. Also archived, and the larger unknown here.

* **A Python 3 port, of unknown size.** The vendored files carry three
  `iteritems` calls (`serverinfo.py:123`, `request.py:540,607`) and
  `xml.etree.cElementTree`, which still imports on 3.9. Whether
  `pycalendar` and the unvendored files are as close is not yet known.

* A `serverinfo.xml` whose `<host>`/`<nonsslport>` name the endpoint
  above. The vendored one says `www.example.com`, which the in-process
  runner never has to dial.

The payoff is worth the work twice over: it exercises Bandit, the
wire and authentication — which `Dav.CalDAVTester.Runner` says
outright it does not — and it checks the in-process port against the
original, where a disagreement means the port is wrong.

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

* `Resource/CalDAV/implicit/copymove/put-restrictions/4.ics` — added `TRANSP:TRANSPARENT` to the attendee's expected copy. The fixture predates CalendarServer's `addTranspForNeedsAction` (`itip.py`), which unconditionally marks a `NEEDS-ACTION` recipient's delivered copy transparent; every other fixture family from the later era (`scheduletag`, `cancels`, `scenario1`) already expects it, and the ten tests comparing against this file test UID and COPY/MOVE semantics, not transparency.

* `scripts/tests/CalDAV/timezones.xml` — the `Timezone cache - aliases` suite's December expectation moved from `1211T140000Z/1211T150000Z` to `1211T150000Z/1211T160000Z`. The fixture bakes in Brazilian daylight saving, which Brazil abolished in 2019, and the suite pins the event to `$now.year.0` — so with any current timezone database, `12:00` in `Brazil/East` on December 11 is `15:00Z`. The test's intent — the server resolves the aliased `TZID` through its own timezone cache rather than trusting the truncated inline `VTIMEZONE` — is preserved and sharpened: a server honouring the inline definition (whose obsolete rules still claim daylight saving) now produces `14:00Z` and fails.

* `Resource/CalDAV/put/2.ics` — expected `DURATION:P1D` changed to `DURATION:P1DT`. The corpus is internally inconsistent about the relaxed-duration repair: this one expectation wants `P1DT` rewritten to `P1D` on store, while six other fixtures across `put.xml`, `errors.xml` and `alarm-dismissal.xml` require the same malformed value to round-trip untouched. Six against one, the round-trip behaviour is the corpus's, and test 1's remaining intent — the malformed value is *accepted* rather than refused — still holds.

* `Resource/CalDAV/acls/17.ics` — the `visible2.ics` body changed from a `VEVENT` to a `VTODO` (same UID, stamp and summary). `acl.xml`'s `Directory list access` test 2 reads the rolled-up calendar as the granted reader and asserts `contains VTODO` / `notcontains VEVENT` — the visible member shown, the per-object-denied `hidden1.ics` (a `VEVENT`) absent. With both fixtures as `VEVENT`s the assertion pair is unsatisfiable by construction; as a `VTODO` the visible member is discriminable and the test's intent — per-object ACL filtering of a collection `GET` — becomes testable. The only other use of the fixture (`proxyauthz.xml`) writes it and never reads the component type back.

* `Resource/CalDAV/depthreportsacl/cal2.ics` through `cal9.ics` — `UID:$uid1:` changed to `$uid2:` … `$uid9:` (upstream generates twenty per file). All nine fixtures shared one UID, three PUTs per calendar, which RFC 4791 section 4.1 forbids within a collection — the suites predate CalendarServer's UID-conflict check and expect all nine stored. Distinct UIDs let every PUT land; the times, the per-object ACLs, and both suites' intent — reports and free-busy filtered object by object — are untouched.

* `Resource/CalDAV/depthreportsacl/6.xml` and `scripts/tests/CalDAV/schedulepostacl.xml` — hard-coded `20060101`/`20060102` moved to `$now.year.1:` substitutions, in the free-busy query's time-range and the expected `FREEBUSY` line respectively. The events both suites schedule sit at `$now.year.1:` already, so the 2006 range matched nothing and the expectation could never be produced; the intent — free-busy filtered by per-object ACLs — is unchanged.

* `Resource/CalDAV/privatecomments/*.ics` — eleven fixtures had `;X-CALENDARSERVER-DTSTAMP=20080827T171052Z` removed from their expected `X-CALENDARSERVER-ATTENDEE-COMMENT` property. The parameter records when the comment arrived, so a live server writes the moment of the run; the fixtures bake in a 2008 timestamp and `privatecomments.xml` passes no `filter` argument, nor does `serverinfo.xml` declare one for this property (it declares three, all on `ATTENDEE`). The expectation was therefore unsatisfiable by any server, upstream's included. What the tests check — that the organiser's copy carries each attendee's comment text, referenced to that attendee by `X-CALENDARSERVER-ATTENDEE-REF`, and that it changes and disappears as the attendee edits and removes it — is untouched.
