# CalDAV Conformance

This file records the CalDAVTester conformance drive: where it ended, how to reproduce the position, and the behavioural models that were built along the way — so nobody re-derives them. It began life as the drive's TODO list; the work is complete, and what remains here is what is still true.

## The position

`MIX_ENV=test mix run priv/conformance.exs` prints the classified position. As of completion:

| Class | Failing | Meaning |
| --- | --- | --- |
| RFC-required | **0** | defects against RFC 4791/5545/5546/6638/7809 behaviour |
| Apple/interop | **0** | CalendarServer behaviour beyond the RFCs — Apple Calendar and Thunderbird interop |
| Incidental | 14 | expectations that cannot be met on principle, each cited below and in the classification file |
| Unclassified | 0 | new failures needing triage |

Every suite classified `:rfc` or `:apple` passes in full. The baseline of passing tests per scenario lives in `test/support/caldavtester/baseline.exs` (regenerate with `mix run priv/baseline.exs`); a unit test fails the build if any scenario regresses below it, and reports improvements so the baseline is ratcheted rather than left stale. `test/support/caldavtester/classification.exs` holds the per-suite classification and is the file to update when a class turns out to be wrong.

## How the drive was run

Three disciplines made it work, and any future change to scheduling or sharing should keep them:

* **Read `rfc/reference/calendarserver/` before inferring behaviour from fixtures.** The CalDAVTester fixtures are that server's literal outputs, and its vendored scheduling sources (`implicit.py`, `itip.py`, `icaldiff.py`, `processing.py`, `peruserdata.py`) answer the questions the RFCs do not. Every model below was read out of the reference, not guessed from diffs; the few times a rule was guessed first, the corpus contradicted it.

* **Measure every change against the whole corpus.** A change that fixes its target suite and quietly costs more elsewhere is a regression; several plausible rules below carry the measurement that killed their first draft. Compare a full run against the baseline before declaring anything an improvement.

* **Fixtures may be repaired only when the test intent survives.** The vendored fixtures are archived and era-drifted; dates outside the runnable range, retired daylight-saving rules and internally contradictory expectations were repaired in place, each documented in `rfc/conformance/caldavtester/FETCHING.md`. A repair that would change what a test *checks* is not a repair — those became incidental classifications instead.

## The scheduling model

The implicit-scheduling engine (`Dav.Cal.Scheduling`) follows CalendarServer's, piece by piece. The load-bearing rules:

* **Announcing.** Nothing is sent when nothing an attendee can see has changed; the comparison is of the *processed* copy (participation restored, sequence synced) against the stored one, with `PARTSTAT` excluded so an echo cannot look like a change. A master-touching update announces the whole set (`filterComponents`) and the recipient's copy is rebuilt from it, stale overrides re-derived from the new master (`deriveInstance`); a master left alone narrows the message to the changed overrides. Each recipient sees only components naming them, with dropped overrides becoming UTC-form `EXDATE`s on their master (`attendeesView`), and an empty view sends nothing.

* **Sequences.** One number for the whole object: `maxSequence(old) + 1` applied to every component, and only when the client left some component at or below its stored counterpart (`needsiTIPSequenceChange`); a client that raised every number is left alone, and no number ever decreases even on a save that tells nobody (`sequenceInSync`). A delete-path `CANCEL` carries two stacked increments — the remove bump plus `generateCancel`'s unconditional `+1` — so an unnumbered event is withdrawn at `SEQUENCE:2`; applying the generator bump to modify-path cancellations measured −9 and is wrong, because there the reference generates from the old copy.

* **Re-asking.** What re-asks an attendee is a change to when the event happens: the per-occurrence list is `DTSTART DTEND DURATION DUE RECURRENCE-ID`, with `RRULE` judged at the series level where a `COUNT`/`UNTIL`-only change is excused (`attendeeNeedsAction`) — `X-` and `SUMMARY` changes deliver but never re-ask. A rescheduled series resets every component at once (`transferItems`' `reschedule` flag) and drops overrides made redundant by the reset. A deliberate reset to `NEEDS-ACTION` travels as `X-CALENDARSERVER-RESET-PARTSTAT` so the recipient's server knows not to restore the stored answer over the question; `RSVP=TRUE` is added by the asking itself — the `REQUEST` message and the delivery stamp — never by a quiet echo, whose `PARTSTAT`/`SCHEDULE-STATUS`/`RSVP` spelling round-trips untouched. An organiser deleting an override without excluding its date has the derived instance restored and re-asked (`coerceAttendeesPartstatOnModify`); a redundant override is simply gone.

* **`SCHEDULE-STATUS` is a per-round delivery record.** A delivering save re-states it: cleared, then `1.2` for everyone reached, `5.3` for a refused delivery, and `2.0` where an auto-managed attendee accepted something *this* save asked — a first invitation or an occurrence its previous line had not answered; a save that merely re-delivers what a room already accepted leaves `1.2`, and a cancellation-only save asks nothing. On the attendee's copy the `ORGANIZER` line carries the reply record, per copy, on every component. A reply lands `2.0` on the replying attendee's lines, deleting `RSVP` only when the answer actually moved.

* **Cancels.** A withdrawn occurrence travels as a `CANCEL` carrying a derived instance — only when the previous rule actually produced that date — and travels *before* the accompanying update, so "already excluded" can only mean the recipient's own exclusion. A person's copy gets a `STATUS:CANCELLED` override inheriting their own state with the paired `EXDATE` stripped; an auto-managed recipient takes the `EXDATE` directly, written in the withdrawn instance's own zone, and a whole-series cancellation clears its calendar outright (`autoprocessing`). A reschedule cancels the whole old series for anyone dropped from the new master (`findRemovedAttendeesOnRecurrenceChange`). Recurrence identifiers compare as UTC instants across the entire cancel path (`getRecurrenceIDUTC`), so a UTC-form `EXDATE` strikes a zone-form override.

* **Replies.** The reply carries the rids the client's save touched — changed answers, withdrawn occurrences, changed travelling extensions, and repaired components echoed at their restored state — and nothing else; an unanswered component echoed into it would stamp the organiser's copy as though a question still open had been processed. An `EXDATE` added with no other word declines the derived instance, but tidying away an instance the organiser already cancelled, or one this attendee already declined, says nothing new. A changed answer on a *cancelled* instance still replies. Outgoing `REPLY` components carry `REQUEST-STATUS:2.0;Success`. On the organiser's side, a stored override missing from a master-carrying reply is answered by an instance derived from the reply's master.

* **The attendee's copy is repaired, not believed.** A copy that lost its master is restored from the organiser's, shaped as a delivery and transparent until answered — but only for somebody named on the organiser's master. An override dropped without an `EXDATE` while the master stays is put back verbatim: declining takes an `EXDATE`, anything less is a client losing data. A component rewritten without its `RECURRENCE-ID` in an instance-only copy is re-identified by `DTSTART`. A `VTODO` that lost its `ORGANIZER`/`ATTENDEE` lines is dressed back in the stored ones, and completing the to-do marks the writer's line `COMPLETED` — `VTODO`-only, because overwriting a scheduled `VEVENT` with plain data is deliberately a removal. An attendee's zone respelling of an unchanged instant is reverted; the `ORGANIZER` line is not theirs to decorate (`SCHEDULE-AGENT` excepted); a travelling `X-` property they omit is restored while a changed value travels; per-user data a lost-master save also dropped (`TRANSP`) is restored — the blanket keep-if-absent that measured −31 was never needed, the corpus distinguishes *repair* from *statement*. An attendee PUT of nothing but foreign cancelled instances removes the object.

* **The Schedule-Tag ledger** (RFC 6638 §3.2.10): applying a reply moves the `ETag` without moving the `Schedule-Tag`; every `ETag` accumulated since the tag last changed still satisfies `If-Match`; the ledger starts over on any client write or fresh delivery. A write conditional on the tag reconciles rather than replaces: stored answers beat the client's stale attendee data, dropped overrides are restored with the writer's series-level answer applied, and an omission is not a decline. `SCHEDULE-FORCE-SEND=REQUEST` re-invites the named attendees, resets them on both copies, sends only to them, bumps nothing, and is consumed rather than stored.

* **Delivery mechanics.** Delivery stores into the copy the recipient already holds, in whichever of their calendars holds the `UID` — but only a copy that *is* the meeting, not an unorganised event sharing its `UID`; a home with no calendar has its default provisioned on first delivery, and `CALDAV:schedule-default-calendar-URL` outlives its calendar, follows a `MOVE`, and may not point at a shared calendar. A `SCHEDULE-AGENT` switch on the organiser throws the recipient's old copy away and starts from the message. A `UID` already scheduled under a different organiser refuses delivery and stamps `5.3`. A resource (room) cannot organise — `Store.unattended?/2` answers what a `CUTYPE` parameter cannot. An attendee who declined but *kept* their copy still receives edits; one who declined by deleting their copy is delivered nothing but still stamped `1.2` on the organiser's side. The refresh after a reply patches other attendees' copies narrowly (`restated_for/5`); re-delivering through the invite pipeline instead measured **−63** — if the refresh is ever widened, do it per property against the `PerUserDataFilter` model, never by swapping the pipeline wholesale.

* **Outbox compatibility.** On an implicit-scheduling server the old explicit event `POST` is accepted, reports each recipient as succeeding, and delivers nothing locally (RFC 6638 appendix A); only the free-busy question is still the Outbox's to answer — capped at thirty calendar users with `5.1` overflow, refusing non-UTF-8 bodies and floating-time bounds. A recipient at a `mailto:` domain other than the organiser's reports `2.0;Success` the way the reference queues iSchedule; an unresolvable user in the organiser's own domain is `3.7`; a non-mailbox URI that resolves to nobody is `recipient-exists`. The server-to-server receiver is different — its messages have no PUT behind them and are delivered.

## The sharing model

Apple's calendarserver-sharing, in `Dav.Cal.Sharing` and the store:

* A shared view *inherits* the origin's stored properties as a floor (`c:Dav.Web.Hook.inherited/3`) — a value stored on the view always wins. The per-user pair, display name and colour, is the exception on *invited* shares: the view is named at accept time from the invitation's summary and painted by the sharee. A *direct* share, being the owner's calendar seen whole, inherits everything, is only for someone with standing access (owner or proxy), and records the canonical origin path.

* Per-user data on shared *objects* — `TRANSP`, alarms — is split by principal in the store on every write, including a `MOVE` landing in a shared collection, so one sharee's transparency never reaches another's read.

* A sharee deleting their view leaves the share: the sharer's record moves to "deleted", the slot is retired (`MKCALENDAR` over it refuses), and a re-share asks afresh while a plain re-invitation keeps the sharee's standing answer. Uninviting an accepted sharee unbinds their view and sends an `invite-deleted` notification titled by *their* name for the calendar; an unanswered invitee just has the invitation withdrawn. A decline's reply notification carries no summary.

* A sharee with write access may change `TRANSP`, alarms and `X-` data — their view — and nothing else (`theirs_to_change/4`, on the `PerUserDataFilter` model); deleting an organiser's meeting is refused through `c:Dav.Web.Hook.removable/3`. A sharee's save into a shared view schedules for the *sharer* (`owner_addresses` resolves through `store.origin`).

* `DAV:displayname` is never synthesised from the URL leaf — absent until somebody sets it.

## Hook seams added for conformance

Optional callbacks on `Dav.Web.Hook`, each added when a behaviour had no seam to live in: `patchable/3` (semantic PROPPATCH validation — free-busy-set hrefs must exist, the default-calendar URL must be an owned calendar), `removable/3` (delete authorisation beyond access control), `relocated/3` (repairing pointers after a MOVE), `inherited/3` (property floors for shared views). On `Dav.Web.Store`: `unattended?/2` (which addresses are auto-managed).

## The incidental class

Fourteen failures are classified `:incidental` — expectations that cannot be met on principle, each cited in `test/support/caldavtester/classification.exs`. The families, so nobody spends time on them again:

* **Pre-normalisation fixtures.** `implicitcopymove`'s "PUT UID restrictions" families compare against `ATTENDEE:mailto:…` with no `EMAIL` parameter, while `implicit/scenario1/simple` requires the same input normalised to `urn:x-uid:…` with `EMAIL=` added. Both cannot hold; the copymove files predate normalisation. (The never-used `EMAIL parameter` feature in `serverinfo.xml` would have been their gate.)

* **Earlier-era cancel behaviour.** Several `implicitcopymove` tests expect the unanswered attendee's copy *removed* on cancel; the current reference marks and keeps it (`processCancel`). Honouring the old behaviour measured −9.

* **Discriminators outside the vendored tree.** `servertoserverincoming` "POST Errors" sends byte-identical anonymous POSTs expecting four different outcomes — upstream's iSchedule endpoint distinguishes them by connection-level facts (its own port, peer authentication) the requests do not carry. Refusing authenticated receiver POSTs measured −6. Its "POST free-busy" test 2 posts the same one-attendee request as test 1 but expects a second attendee's busy time.

* **Contradictory postures.** `duplicate_uids.xml` wants a plain same-`UID` write refused across the home while `implicitcopymove` requires it allowed; the `no-duplicate-uids` feature is not declared, so that file is skipped, and `copymove.xml`'s one overwrite-move test that needs the refused posture is cited. One `implicitbadclients` client-repair test conflicts with the RFC-required cancel model and was ceded under the RFC-first priority.

* **Hard-coded dates.** One `impliciterrors` test carries a 2005–2009 date that cannot be made current without changing what it tests. (Thirteen others in this family were repairable and were repaired — see `FETCHING.md`.)

## The harness

`Dav.CalDAVTester` runs the vendored suites in-process against the library. What its design deliberately does and does not do:

* **`Features.@declared` is hand-maintained and must not adopt `serverinfo.xml`'s list.** Upstream declares 84 features — the set CalendarServer implements. The declaration is a claim about *this* server; wiring the vendored list through would run suites we cannot pass and report their failures as ours. One entry per implemented feature.

* **`WAITDELETEALL`'s count is deliberately not asserted.** Upstream polls for up to thirty seconds until the count matches; this harness answers immediately, so refusing cascades — 222 failures, none about the thing they report. Asserting the count and emptying anyway surfaces 102 unattributable mismatches (60 if narrowed to surpluses, which are a *previous* suite's residue). Re-deriving this costs an afternoon; it is also recorded at the call site.

* **The wait knobs are inert.** `<waitcount>`, `<waitdelay>` and `<waitsuccess>` all describe waiting for a server working in the background; this one is synchronous and in-process, so every `WAIT` collapses to one check and a retry would return the same answer. They matter only if the harness ever grows an asynchronous mode.

* **Substitutions.** All 71 `serverinfo.xml` substitutions are read from the vendored file, the account count derived from it rather than restated. Per-request `<substitute>` elements rewrite fixture placeholders (two suites silently depend on it). The comparators mirror upstream's semantics where they are documented only by use: `ignoremissing` suppresses surplus-href checks, href comparisons ignore trailing slashes, and `calendarDataMatch` applies the standing property filters from `serverinfo.xml`.
