# Status

Where the CalDAVTester conformance work stands, and how to continue it. Written 2026-09-05, against `c15a526` plus the force-send ordering fix.

`CONFORMANCE.md` explains *what* was built and why each remaining failure is acceptable. This file is the working state: the numbers, the loop, and what to pick up next.

## The position

| | |
| --- | ---: |
| Scenarios | 162 |
| Tests | 5,144 |
| Passing | 5,094 |
| **RFC-required failing** | **0** |
| Apple/interop failing | 10 |
| Incidental, cited | 40 |
| **Unclassified** | **0** |
| Features declared | 50 |

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

### Pools not yet opened — 18 files, 419 tests

Each is gated shut by a feature this server does not implement. Declaring a feature without building it inflates the denominator and turns the conformance figure into a claim, so the gate stays until the code exists.

| pool | tests | needs |
| --- | ---: | --- |
| `implicitgroup.xml`, `trash-implicitgroup.xml` | 97 | group attendee expansion, `control-api` |
| `partitioning-*.xml` | 48+ | multi-node partitioning |
| `dropbox.xml`, `implicitdropbox.xml` | 66 | legacy dropbox |
| `polls.xml` | 28 | `VPOLL` |

**Those counts are upstream's `<test>` elements and they over-count.** Several files comment whole suites out — `availability.xml` was listed at 29 and yielded 7 live tests when it opened. Treat the column as an upper bound, and measure the file before planning around it.

The Apple queue is now 10, and it sits in four files:

| where | failing | what it wants |
| --- | ---: | --- |
| `privatecomments.xml` | 1 | the organiser's copy restamped when only a comment changed |
| `implicitschedulechanges.xml` | 3 | one problem — see below |
| `trash.xml` | 4 | a sharee's delete, splitting round a trashed copy, an attachment reclaimed too early |
| `default-alarms.xml` | 2 | an `ETag` on a sharee's own write, and an invitation taking a default |

**This table was wrong until 2026-09-05 and is worth reading twice.** It listed fourteen of what were then nineteen as `sharing-quota.xml` and called the queue closed. `sharing-quota.xml` is classified `:incidental`, not `:apple` — it is part of the forty, and always was. Nobody had listed the Apple queue test by test, because `Corpus.headline/1` breaks down only `:unclassified` and `:rfc`; the summary line was taken on trust through several edits. Run the listing before planning against this table.

**Every sharing file now passes in full.** The group-sharing tail is closed.

`sharing-quota.xml` is **not winnable**, which an earlier note in this file guessed wrong in the other direction: twelve of its fourteen compare byte counts that encode the reference's on-disk per-user wrapper, and the other two want a second object with the same `UID` in one calendar, which RFC 4791 section 5.3.2 forbids. The behaviour underneath — a shared calendar's bytes belong to its owner — was already right and is now covered by `Dav.Cal.SharingTest` rather than by a comment alone. Cited in full in `classification.exs`.

**The auto-scheduling work is finished. What is left is four clusters of real behaviour, not a closed queue.**

`implicitschedulechanges` looked like three mechanisms and is really one, plus its own fallout:

* **Two** want `DTEND` named when the *start* moved and the end is written as a `DURATION` (`Organizer Changes` 6, `Multi-instance change` 6). Neither copy has a `DTEND` at all, so `Dav.Cal.Changes` correctly reports none; the reference names it because `Component.normalizeAll` has materialised the end before it diffs. That call is not in the vendored subset — `ical.py` is not there — so confirm it before building to it.

* **One** is not a fault at all. `Organizer Changes` 8 counts two Inbox items where one is wanted, and the second is there because `Runner.run_test/2` halts a test at its first failing request — so when 6's verify fails, the `DELETEALL` after it never runs and the message stays. Fixing the `DTEND` naming closes both.

  Worth knowing generally: **a failing test can leave state that fails a later one**, and the queue's per-test listing cannot show that. Before treating two failures in one file as two problems, check whether the first one's test had cleanup after the failing request.

`Attendee instance change` and `Private Comment` are both closed — see below. `scratchpad/suite.exs` (the pattern, not the file) is what cracked the second: `Scenario.read/1` gives a struct whose `suites` can be filtered before `Runner.run/2`, so a probe's output belongs to a known round. This file runs ten suites and probe output from all of them is unattributable otherwise.

`privatecomments` was six and is now one; see below. It went the same way as the auto-schedule tail: three separate faults, none of them what its citation said.

The "auto-schedule tail" is closed. All six of its files pass in full, and none of the four faults was what its label said — most were the same shape: **an answer computed correctly and then overwritten while the outgoing copy is built.** That is worth knowing before anyone models a "two-phase delivery" that was never the problem; CONFORMANCE.md traces each to the line, along with the engine difference that produced three of them.

`trash`'s four are three problems, all now traced. A sharee's delete keeps their *rendering* rather than the object, so recovery restores a copy stripped of the owner's per-user parts. An attachment is reclaimed when its event is trashed rather than when the trash is emptied, which makes one test pass for the wrong reason — `readable/2` answers `403` for a file that is not there, which reads the same as "hidden while trashed". And the two `Organizer splits it` tests want a copy that was split *while it waited in the trash* to come back as both halves, each carrying the answer the attendee gave before they trashed it; `recovered/2` puts back what it kept, by `UID`, and knows nothing of splitting. That last one is the largest piece of work left anywhere in this queue.

The remaining gated pools are all Apple legacy (`dropbox`, 66), a dead draft (`VPOLL`, 28), a deployment topology (`partitioning-*`), or a suite feature that is not a protocol (`implicitgroup`'s directory-driving half). Those are a judgement about whether the feature is worth building. The nineteen above are not: they are behaviour this server already claims.

Read a file before committing to it, and run the listing before believing a tally. Four estimates in this section have now been wrong — the Apple queue's own contents most recently — `sharing-quota` was called winnable and is not, per-user data was called large and was small, and `sharing-groups-changes` was called 16 tests of group re-derivation when five of them were a broken verifier.

Of the gated pools, every remaining standard is now declared. What is left needs either a feature of real size or a deployment this library is not:

* **`implicitgroup`** is the largest at 97, and wants two things — expanding a group attendee into its members, and the `control-api` the suite uses to change directory membership mid-scenario. The second is not a protocol, so a chunk of the file is unreachable without inventing one.

* **`dropbox`** is Apple's pre-managed-attachments model, superseded by the managed attachments this server already implements. Building the legacy alongside is 66 tests for a feature Apple itself replaced.

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

* **Apple's own harness now drives this server** (`Dav.CalDAVTester.Endpoint`, `priv/serve.exs`, `priv/caldavtester.py`). The in-process runner says outright that it exercises no Bandit, TLS, authentication or concurrency — it measures the protocol, not the deployment. This measures the deployment: the same store, plug options and provisioning behind a socket, with the Basic authentication the scenarios assume, and the real CalDAVTester pointed at it. `propfind` 27/27, `get` 16/16, `delete` 3/3, `options` 4/4.

  Nothing vendored was modified. The harness is Python 2 and archived, so the port is a build step (`priv/caldavtester.py`) that copies the tree into `_build/` and transforms it — `git diff` against upstream stays empty and the transformation is reviewable as code. FETCHING.md lists what it does; the one worth knowing is `response.status / 100 == 2`, which divided to `2` on Python 2 and is `2.07` on 3, so every multi-status answer read as a wrong status code.

  **And it immediately found two defects the in-process runner cannot see.** `put.xml` round-trips `X-Test:Just some text\, <- here.` back as `X-TEST:Just some text, <- here.` — the `TEXT` escape is dropped and the name upper-cased. `SUMMARY:a\, b` survives, so the fault is specific to extension properties: they are not treated as `TEXT`-valued on the way out. Losing a `\,` changes the value a client stored, which is a correctness bug against RFC 5545 section 3.3.11, not a fidelity nicety. Our own comparison could never have caught it — `Dav.CalDAVTester.Calendars.compare/3` parses both sides and compares them structurally, where upstream's `calendarDataMatch` compares the text.

* **The asking takes nothing away** (`Dav.Cal.Scheduling`). `implicitschedulechanges.xml` 43 to 44; the Apple queue fell 11 to 10. An organiser restating an answer somebody has already given may write `RSVP=TRUE` beside it, and `asking/1` stripped it from the outgoing message — so the recipient's `schedule-changes` said nothing had moved on a line that had. `delivered/2` already states the rule for the delivery mark: add the asking where an answer is still wanted, take nothing away. `asking/1` now has its own `asked/1` that does the same. Deliberately narrow: `awaiting/1` has five callers and two apply it right after *setting* a `PARTSTAT`, where clearing a stale `RSVP` is right.

  No unit test. It needs an organiser restating an answer already recorded, and three attempts at a fixture passed for other reasons — on a create the attendee is coerced to `NEEDS-ACTION` and asked regardless, which makes the assertion vacuous. Covered by the suite, and the code says so.

* **An occurrence a rule alone makes is still one the recipient holds** (`Dav.Cal.Changes`). `implicitschedulechanges.xml` 42 to 43; the Apple queue fell 12 to 11. An attendee answering one occurrence of a series sends an override the organiser has no component for, and `changes/3` wrote `<CS:changes/>` empty for it — telling the organiser a reply arrived but not that anybody's `PARTSTAT` moved, which is the whole of what a reply says. It is now compared against the instance the master implies, as the reference derives one to diff against (`deriveInstance`, the `oldset - newset` branch of `whatIsDifferent`). The "wholly new component" rule still holds for a component that genuinely is new — a recipient holding nothing at all. `test/dav_cal_changes_test.exs` is new; `describe/4` is pure, so it needs no fixture.

* **A restoration outranks the cancellation that withdrew it** (`Dav.Cal.Trash`, `Dav.Cal.Scheduling`). `trash.xml` 91 to 92; the Apple queue fell 13 to 12. Trashing an invitation sends a `CANCEL` numbered one past the copy it withdrew, so putting the event back at its old number hands every attendee a `REQUEST` older than the cancellation they hold, and a client that honours `SEQUENCE` keeps the meeting struck through. `Dav.Cal.Trash` marks the restoring save `recovered: true` and the numbering happens in `sequenced/2`, where it belongs.

  The first attempt renumbered the body inside `Dav.Cal.Trash` and cost five other tests: a plain event came back carrying a `SEQUENCE` it never had, and the organiser case landed on `1001` because the engine's own restore rule (`maxseq + 1000`, from `implicit.py`) then fired on top of it. Putting the rule in the engine fixed both for free — `renumbered/4` numbers nothing when nobody is being told, so an event with no attendees and one with `SCHEDULE-AGENT=NONE` need no special case. `Dav.Cal.Trash` also had `DBGTRASH` debug output committed in it, printing on every delete and recovery; removed. `test/dav_cal_trash_test.exs` is new — the module had no unit coverage at all.

* **A sharee starts with no alarm, and says so** (`Dav.Cal.Sharing`). `default-alarms.xml` 33 to 34; the Apple queue fell 14 to 13. An invited view now reports all four `default-alarm-*` properties present and empty rather than absent, so a client can tell an unset reminder from an unsupported one. They go through `inherited/3`, which `Dav.Web.Plug` merges *under* the view's own properties, so the sharee's value wins the moment they set one.

  One wrong turn worth recording: a probe looked like the sharee's *home* alarm was leaking into the view, and stopping shared views inheriting from the home above them fixed nothing — the alarm was the sharee's own, set on the view two tests earlier. Reverted. Read the fixtures before believing a probe about where a value came from.

* **What an attendee said is theirs** (`Dav.Cal.Scheduling`, `Dav.Cal.Object`). `privatecomments.xml` 68 to 73; the Apple queue fell 19 to 14. Three faults, none of them what its citation said. An *empty* `X-CALENDARSERVER-PRIVATE-COMMENT` is a client taking back what it wrote, not silence, and the tagged line stays with nothing in it — dropping it lost the record that the attendee ever commented, and every later round then disagreed. An organiser's client that does not understand `X-CALENDARSERVER-ATTENDEE-COMMENT` drops it from every save, so the lines a save leaves out are restored — and only those, because the fixtures show a save that *carries* a line with new text keeps the organiser's edit. And two lines tagged with the same attendee are refused as `CS:no-duplicate-private-comments` rather than accepted, because nothing decides which the organiser's copy should keep.

* **The Apple queue was never what this file said** (`Dav.CalDAVTester.Corpus`, STATUS.md, README, CONFORMANCE.md). No test moved. The queue's own summary here claimed fourteen of its nineteen were `sharing-quota.xml`; that file is cited `:incidental` and has never been in the queue. `Corpus.headline/1` broke down only `:unclassified` and `:rfc`, so the Apple tally was a number nobody could check, and it survived several rounds of edits — including four in this drive — on trust. The report now lists `:apple` test by test as well, and the table above says what is actually in it: `privatecomments` 6, `implicitschedulechanges` 5, `trash` 5, `default-alarms` 3, all of them live behaviour rather than the closed queue this file described.

* **A record, not a question, on somebody else's copy** (`Dav.Cal.Scheduling`). `implicitautopast.xml` 23 to 24, complete; the Apple queue fell 20 to 19, and **the auto-schedule tail is closed**. A room accepts what is still to come and leaves the occurrences already over unanswered, so the server splits those out of the master to record the difference. `asking/1` then put `RSVP=TRUE` on every unanswered attendee of the outgoing `REQUEST`, which is right for the recipient and wrong for everyone else's view of the room: on their copy that override is a record, and re-asking there showed a bystander a question that is not theirs to answer. `recorded_room/4` states the room's participation as the organiser's copy holds it and takes the asking back off a derived override, leaving the recipient's own line alone. Two differences were stacked here, the verifier reporting one at a time, and the citation described only the first.

* **A forced re-invitation reaches one attendee without disturbing the rest** (`Dav.Cal.Scheduling`). `implicitauto10.xml` 23 to 25, complete; the Apple queue fell 22 to 20. Two faults, and the citation named neither. `cleared_status/2` wiped `SCHEDULE-STATUS` from every attendee line whenever a round delivered anything — harmless when the round is the whole attendee list, but a `SCHEDULE-FORCE-SEND` re-invitation names its recipients, so a reply already in hand was reported as never having arrived. And `asked_afresh/3` put the question back over a re-invited recipient's carried answer on their own copy, which is right for a person and threw away the reply for a room — the same shape as the entry three below. Both found by dumping each comparison rather than reading the citation.

* **Ask the re-invitation question of the client's data** (`Dav.Cal.Scheduling`). No test moved; a wrong behaviour went. The entry below closed `implicitauto9` by comparing `PARTSTAT` in the set of things the attendees hold, and that set is built *after* the auto-answering — so a room's own acceptance read as an organiser's edit, and a `SCHEDULE-FORCE-SEND` re-invitation that changes nothing was renumbered. The reference numbers that one not at all. `re_asked?/2` now asks it of the client's body against the stored copy, which is where the reference asks it (`_diffNeedsAction`, `icaldiff.py`), and exempts a merging write — a stale client's `NEEDS-ACTION` is ignorance, not a question, and the reference merges the stored answers in before diffing (`_organizerMerge`). That exemption was found by the corpus: without it `implicitscheduletag` lost a test and the RFC-required queue opened.

* **A re-invitation is a change worth sending** (`Dav.Cal.Scheduling`). `implicitauto9.xml` 17 to 19, complete; the Apple queue fell 24 to 22. An organiser writes a re-invitation as `PARTSTAT=NEEDS-ACTION` and nothing else, and the test deciding whether a save is worth announcing deleted `PARTSTAT` before comparing — so the whole of the change compared equal to the stored copy and no `REQUEST` went out. The filed label — "a second scheduling round" — was wrong: dumping the components stage by stage showed the resource already re-accepting on the first pass. The first form of the fix put `PARTSTAT` into that comparison and was too broad; see the entry above.

* **A room answers the asking it was given** (`Dav.Cal.Scheduling`). `implicitauto10.xml` 22 to 23; the Apple queue fell 25 to 24. The room's auto-accept was computed correctly and then wiped by RFC 6638 section 7.1's `SCHEDULE-FORCE-SEND` reset, which ran *after* the rooms had answered. Being asked again is what a room answers to, so the reset now runs first. Found by bisecting the organiser branch with a probe at each stage rather than by reading; nothing else in the corpus moved.

* **`implicitauto10` diagnosed, not fixed.** The room *does* auto-accept: `auto_answers/2` judges it free and answers `ACCEPTED`, and `auto_answered/3` stamps `SCHEDULE-STATUS=2.0` — which the stored copy keeps. Only the `PARTSTAT` is dropped, between there and `record/5`. Together with `implicitautopast`, both traced parts of the "auto-schedule tail" are an answer computed right and then overwritten, not a missing delivery phase. No code changed.

* **`implicitautopast` diagnosed, not fixed.** Traced to the exact components: of the event's two past overrides, the client's keeps `RSVP` and the server-derived one must not, and `asking/1` re-adds it to both while building the outgoing `REQUEST`. The earlier reading — "`RSVP` on a past occurrence" — was wrong, and the citation now says what it actually is. No code changed.

* **Which route you took to a calendar** (`Dav.Cal.Sharing`). `sharing-groups.xml` and `sharing-unshare-groups.xml` both complete; the Apple queue fell 27 to 25 and **every sharing file now passes in full**. A view made by `?action=share` is a proxy's view and shows a proxy's access, where an invitation reaching the same person by another route was winning. The marker is written whether or not the collection was created just then — binding a calendar already in your home is you saying which route you are taking, and writing it only on creation is why the first attempt changed nothing.

* **A notification says what the person holds** (`Dav.Cal.Sharing`). `sharing-groups.xml` 83 to 84 and `sharing-unshare-groups.xml` 84 to 87; the Apple queue fell 31 to 27. Only the *access* is taken from the merged view — the first attempt at this took a whole merged record and regressed the invitation state, since a newly created record says `noresponse` and overwrote people who had already accepted. Access and state are separate questions and are now answered separately.

* **A share to a group is a share to the group** (`Dav.Cal.Sharing`, `Dav.CalDAVTester.Control`). `sharing-groups-changes.xml` went 4 to 20 — the whole file — and the Apple queue fell 47 to 31. The group is now recorded in its own right rather than only expanded, so an empty group is still a share; `regrouped/2` re-derives a calendar's group shares after membership changes; and the harness grew the suite's `/control` back door. The last five failures were a **verifier** bug: a predicate followed by more path had its tail silently swallowed, so `href[=X]/../access/read` never checked the access. That is the failure mode this harness exists to avoid, and upstream's own assertions are now tests here.

* **Quota on a shared calendar, read rather than assumed.** `sharing-quota.xml` gains nothing: its numbers encode the reference's storage layout and two of its writes are refused by RFC 4791. The citation now says which, and the behaviour the file is actually about is covered by tests. No production code changed.

* **Withdrawing one share out of several** (`Dav.Cal.Sharing`). `sharing-unshare-groups.xml` went 73 to 84 and the Apple queue fell 58 to 47. Uninviting a group dropped every record the affected people held rather than the ones that group gave — the surrounding comments already said it should be the second. The withdrawal now carries its source, and who is left with nothing is worked out afterwards. Nothing else in the corpus moved.

* **Per-user data on a shared calendar**, widened from `TRANSP` and `VALARM` to every `X-` property and subcomponent — the rule `Dav.Cal.Object` had written down all along for deciding what a sharee may change. `sharing-traveltime.xml` went 9 to 27 and the Apple queue fell 76 to 58. `X-CALENDARSERVER-ACCESS` stays shared: a privacy mark kept per reader stops being one. It also turned up a store bug — per-user data outlived the resource it belonged to, so an object written at a deleted one's path inherited a stranger's alarms.

* **Apple's travel time** (`Dav.Cal.Travel`). `implicit-traveltime.xml` in full, 25 tests: the journey either side of an event occupies its own attendee, so the busy period starts earlier and ends later by what that person wrote. The search window widens by the travel before occurrences are looked for, or a slot half an hour before an unreachable meeting reports free. **`sharing-traveltime.xml` did not follow** — 18 tests, classified `apple`: on a shared calendar each sharee's travel is per-user data, which is the next section's subject. Nothing else in the corpus moved.

* **RFC 7953 availability** (`Dav.Cal.Availability`). `availability.xml` in full, 7 tests. A `VAVAILABILITY` kept in `CS:calendar-availability` on the Inbox says which hours its owner would accept a meeting in; the available windows are expanded and subtracted from the query window, and the remainder is reported at the component's `BUSYTYPE` — `BUSY-UNAVAILABLE` by default. `Dav.Cal.FreeBusy` now writes a period the way its own specification's examples do: RFC 5546 busy time as a start and a duration, RFC 7953 unavailable time as two instants. Nothing else in the corpus moved.

* **What a `GET` on a collection does**, in `Dav.Web.Plug` (`directory listing`). 91 tests gained across three files — `collection-redirects.xml`, `directory.xml` and two gated suites of `get.xml`, all passing in full. A collection addressed without its trailing slash redirects to the one it has; a deployment may ask for a listing with `listings: true`; a browser gets that listing ahead of whatever an extension would render; and a collection read carries an `ETag` over the rendering plus a `Last-Modified`, and answers `304`. `c:Dav.Web.Hook.rendered/2` gained `{:error, :forbidden}` for a collection that may be addressed but not enumerated. Nothing else in the corpus moved.

* **jCal** (`Dav.Cal.JCal`) — RFC 7265, calendar data as JSON. 52 tests gained, `json.xml` in full. One syntax is stored, iCalendar, and the JSON is converted at the edges: a codec keyed on RFC 5545's value-type table, plus negotiation on six surfaces (`Accept`, `Prefer: return=representation`, a report's `calendar-data content-type`, an Outbox `POST`, a bulk request, and `CALDAV:calendar-timezone`). Three base seams came out of it — `c:Dav.Web.Hook.taken/4` and `c:Dav.Web.Hook.offered/6` for negotiation, a revising `c:Dav.Web.Hook.patchable/3`, and `Dav.Xml.parse_propfind/1` now returning the attributes a client wrote on the properties it asked for. Nothing else in the corpus moved, which was worth checking: the change touches `PROPFIND`, `PROPPATCH`, `GET`, `PUT` and both reports.

* **Apple's bulk `POST`** (`Dav.Cal.Bulk`), both forms — the simple `VCALENDAR` divided per `UID` and the `MM:multiput` CRUD document — with `MM:bulk-requests`, `X-MobileMe-DAV-Options: return-changed-data` and the ctag `If` condition. 59 tests gained, `bulk.xml` in full. Two seams came out of it: `Dav.Web.Write.document/5` is the write `PUT` performs, now shared rather than reimplemented, and `Dav.Web.Hook.removing/2` and `removal/3` are the delete side of the same thing. One scheduling rule moved with it: `SEQUENCE` rises on a significant organiser change rather than only when a message goes out, which cost nothing elsewhere in the corpus.

* **RFC 7808 time zone service** (`Dav.Cal.TimezoneService`) and **CalendarServer's older query dialect** (`Dav.Cal.TimezoneQuery`), both over one catalogue in `Dav.Cal.Zones`, which reads the same IANA distribution the `tz` dependency compiles against. 87 tests gained. Nine cited failures are all one thing: `calendarDataMatch` compares against `VTIMEZONE` captured from CalendarServer on the 2016 database, including `TZNAME` spellings IANA's data does not carry.

* **RFC 4331 quota** through a `c:Dav.Web.Store.quota/2` callback, so which parts of a tree are bounded stays the store's decision. +50.

* **One corpus run per close-out** (`Dav.CalDAVTester.Corpus`), replacing four. This was a response to the review cost exceeding the work.
