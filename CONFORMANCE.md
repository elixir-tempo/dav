# CalDAV Conformance

This file records the CalDAVTester conformance drive: where it ended, how to reproduce the position, and the behavioural models that were built along the way — so nobody re-derives them. It began life as the drive's TODO list; the work is complete, and what remains here is what is still true.

## The position

`MIX_ENV=test mix run priv/conformance.exs` prints the classified position. As of completion:

| Class | Failing | Meaning |
| --- | --- | --- |
| RFC-required | **0** | defects against RFC 4791/5545/5546/6638/7809 behaviour |
| Apple/interop | 6 | the open tail of the room auto-scheduling work — see below |
| Incidental | 15 | expectations that cannot be met on principle, each cited below and in the classification file |
| Unclassified | 0 | new failures needing triage |

Every suite classified `:rfc` passes in full. The Apple queue reopened deliberately, twice. Declaring `auto-accept` brought seventeen previously excluded room-scheduling files into the corpus (about 420 tests), of which 6 still fail: the `SCHEDULE-STATUS` 1.2-versus-2.0 delivery-mark rules across rounds (`implicitauto9`, `implicitautopast`) and parts of the `accept-if-free` delegate flow in `implicitauto10`. These need the reference's two-phase delivery — an attendee's reply re-delivering the organizer's updated copy to the other attendees — which this engine's single-pass organizer-side answering does not reproduce; the `SEQUENCE` propagation cases that used to sit beside them were closed by the quiet-copy adoption rule below. Declaring `managed-attachments` brought the attachment files in (about 315 tests), and all five — core, recurrence, implicit scheduling, sharing and the legacy dropbox restrictions — now pass in full; see the attachments model below. Declaring `private-events` brought `privateevents.xml` in (174 tests, passing in full): the access model below, and with it the `ACL` method and the rolled-up calendar `GET`. Declaring `ACL Method` then brought `acl.xml` in (42 more tests), which grew the method from grant-only to the full grant/deny model below, and declaring `per-object-ACLs` opened the rest of it plus `depthreportsacl.xml` and `schedulepostacl.xml` (14 more) — all passing in full. Declaring `recurrence-splitting` brought `recurrence-splitting.xml` in (106 tests, passing in full): the splitting model below. The baseline of passing tests per scenario lives in `test/support/caldavtester/baseline.exs` (regenerate with `mix run priv/baseline.exs`); a unit test fails the build if any scenario regresses below it, and reports improvements so the baseline is ratcheted rather than left stale. `test/support/caldavtester/classification.exs` holds the per-suite classification and is the file to update when a class turns out to be wrong.

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

## The auto-scheduling model

Declaring `auto-accept-modes` brought `implicitautomodes.xml` (126 tests) and `implicitautogroup.xml` (32) into the corpus, and both pass in full. The mode machinery already existed for `accept-if-free`; what the drive added:

* **Mode `none` is a resource somebody manages by hand.** Its invitations queue in its Inbox like anyone else's, nothing answers on its behalf, and none of the quiet-copy tidying applies — the mode gates `auto_managed?` and every unattended-recipient rule.

* **A group-restricted room declines outsiders outright.** `c:Dav.Web.Store.auto_accept_group/2` names who may book; a member's invitation is answered by the room's own mode, anyone else's is declined whatever the calendar says.

* **A mixed answer keeps the message in the Inbox.** When some occurrences answered and an active one stayed `NEEDS-ACTION` — accept-if-free while busy, decline-if-busy while free — the message is not consumed: the pending part is what a delegate has to see.

* **Derived overrides are spelled from the answered master.** The reference resets the master first and derives from the result, so a derived line that then changes again carries an explicit `PARTSTAT` rather than an implied one.

* **`P1DT` is read as `P1D`.** A trailing `T` announcing time components that never come is malformed, Apple's parser tolerates it, and real clients wrote it — `Dav.Cal.TimeRange` strips it before parsing, which is also what `put.xml`'s relaxed-parsing suite checks.

Two rules landed after the attachments drive closed the earlier `SEQUENCE` cases:

* **A withdrawal numbers the quiet copy it lands on.** When an instance-cancellation reaches an auto-managed recipient, each surviving component adopts the message's version — rid-matched where the message names it, and for a copy held as one series (master present) the highest number offered — but only when that number is exactly one above the component's own: the contiguous round it closed. A copy of individually invited instances (no master) renumbers only rid-matched components, and nothing ever moves by more than one step at once.

* **Re-affirming an answer changes nothing.** The per-occurrence judge writing the answer a line already carries leaves the parameters exactly as the client spelled them — `RSVP=TRUE` echoes included — and the delivery mark (`SCHEDULE-STATUS=1.2`) adds the asking only to still-unanswered lines, never taking an echo away. An occurrence already over keeps `NEEDS-ACTION` with the question withdrawn (`RSVP` dropped), and an implied `NEEDS-ACTION` keeps the client's spelling — the absent parameter is the value.

RFC 6638 auto-scheduling for rooms and resources, in `Dav.Cal.Scheduling` with the `auto-accept` feature declared. The model is the reference's `checkAttendeeAutoReply`, implemented organiser-side since every copy is stored here:

* Every occurrence inside a year window is judged for each auto-managed attendee: an occurrence already over keeps its `NEEDS-ACTION`, a free one is accepted, a booked one declined — the free-busy check runs against the room's own calendar, excluding the event's own `UID`. All occurrences agreeing, the whole object answers at once; mixed, the master takes the majority answer and each differing occurrence stands in an override, derived from the master where the rule alone produced it (`X-DAV-SPLIT` marks a derived override transiently so the organiser's copy does not re-ask the room it split out).

* Answering modes come from the deployment's directory through `c:Dav.Web.Store.auto_schedule_mode/2`: `automatic` (accept free, decline busy), the always/if-free/if-busy variants — the harness runs `resource08` as `accept-if-free`, whose busy invitations queue in its Inbox for a delegate. An auto-managed recipient's Inbox consumes what the server answered; a message it could not answer, or one wholly in the past, is not stored.

* `SCHEDULE-STATUS=2.0` is the record of an answer, marked per round: a delivery whose auto-processing answered nothing — a wholly past event, a mode that held its peace — leaves the plain `1.2`. The room's own copy keeps the delivered answer, turns transparent when declined, and carries the organiser's `1.2` mark only when a reply was actually made. The `CUTYPE=RESOURCE` a client omitted is materialised from the directory the way `CN` is.

* A declined booking is still delivered: the room's calendar records what it turned down, transparent. A room's kept components take the message's `SEQUENCE` per occurrence (`sequenceInSync`), which people's copies do not.

* Later refinements, each measured against the whole corpus: per-occurrence answers restricted to components that name the room; all-day (date-valued) occurrences spelled correctly in derived overrides; `TRANSP` forced to match the answer on every processed component; a room's freshly declined booking written down where a stale refusal is not recreated; a copy a cancellation leaves empty — or holding nothing the room still accepts — deleted; the master's `SEQUENCE` following only when the room's own line was re-answered, an override's only when the client renumbered it; exclusion-cancellations delivered to whoever held the withdrawn instances. The open tail (12 tests, classified `:apple`): the `SCHEDULE-STATUS` 1.2-versus-2.0 delivery-mark rules, a few `SEQUENCE` cases, and parts of the delegate flow in `implicitauto10`. `implicitautomodes` and `implicitautogroup` stay excluded — they drive the deployment's mode switches through CalDAVTester's `control-api`, which the harness does not model.

## The delegation model

Apple's calendar-user-proxy extension, in `Dav.Cal.Delegation` (`proxy` declared, `calendar-proxy` in the `DAV` header). `calendaruserproxy.xml`, `implicitproxy.xml` and `sharing-proxies.xml` pass in full. This is also where access control arrived: the drive that landed it wired the first real read/write enforcement.

* **Grants are `PROPPATCH`es of `DAV:group-member-set`** on a principal's `calendar-proxy-read` / `calendar-proxy-write` child. Members must be spelled canonically — an alias spelling is refused the way the reference refuses a name it cannot place — and a directory-provided group (a room's) is locked against editing. The event bodies of the grant records are inverted into `DAV:group-membership` and `CS:calendar-proxy-read-for`/`-write-for` on every principal, and `DAV:expand-property` follows hook-contributed properties like stored ones.

* **Enforcement**: reading anything in a calendar home takes being its owner, an administrator (`:administrators` plug option), a proxy of either grant, or a sharee of a calendar on the path — consulted by `PROPFIND` and `GET` through the `readable/2` seam, answered `403` `DAV:need-privileges`. Writing (`PUT`/`MKCOL`/`MKCALENDAR`, via `creatable/3`) takes the write grant; so does speaking through the owner's Outbox, refused `CALDAV:organizer-allowed`. A write-proxy also passes the organizer-integrity checks (`theirs_to_change`, `removable`) as the owner.

* **A proxy acts as the delegator.** Writes through a view attribute per-user data — alarms, transparency — to the view's home owner, not the caller, and `DAV:principal-match` `self` matches the caller's principal plus every group whose `group-member-set` names them (RFC 3744 section 9.3), one level into the principal tree so proxy groups are found.

* **Extended free-busy** (`extended-freebusy` declared): `X-CALENDARSERVER-EXTENDED-FREEBUSY:T` on a free-busy `POST` embeds the events beside the periods, per attendee. A privileged asker — the calendar's owner, an administrator, a proxy — sees them whole; a room's schedule is public but only in outline (timing, organizer, attendees — no summary); anyone else gets times alone. An `X-CALENDARSERVER-ACCESS`-restricted event contributes its busy time and shows to nobody but its own calendar's owner.

* **Per-proxy properties**: `calendar-color`/`calendar-order` written by a non-owner land in a per-principal overlay the owner never sees; `DAV:acl` answers only where `read-acl` would be granted — the owner and the administrators.

* Two harness repairs mattered: the admin account (and room principals) resolved to the *first user* through the numbered-account fallback, invisible until access control told callers apart; and bare ancestry placeholders shadowed room-principal resources, so their `owner` never resolved canonically.

## The access model

Apple's private events — `X-CALENDARSERVER-ACCESS` — in `Dav.Cal.Access` (`private-events` declared, `calendarserver-private-events` in the `DAV` header), with the `ACL` method in `Dav.Web.Grant`. `privateevents.xml` passes in full, and the load-bearing rules are:

* **The mark lives beside the data, not in it.** A `PUT` carrying `X-CALENDARSERVER-ACCESS` stores the level as a protected dead property and strips the property from the stored body; every read re-injects it. That is what lets the mark survive a rewrite that omits it, and it is why anything that consults the mark — the extended free-busy hiding rule included — must ask `Dav.Cal.Access.level/2` rather than parse the body.

* **The mark is the owner's alone.** Only the calendar-home owner (or a write-equivalent: administrator, write proxy) may set or change a level, and a non-owner may not rewrite an event held at any non-`PUBLIC` level at all — refused `403` before the write, `CS:valid-access-restriction-change` when a sharee restates a different mark than the one held.

* **Each level is a view.** `PUBLIC` shows everything; `PRIVATE` does not exist for anyone but the owner — `GET` and named `REPORT` hrefs answer `403`, a query drops it silently, and a `PROPFIND` listing names it with a bare `403` response row rather than describing it; `CONFIDENTIAL` shows timing alone (`UID`, the date properties, the recurrence set, `STATUS`, `TRANSP`); `RESTRICTED` adds `SUMMARY` and `LOCATION`. Filtering happens at disclosure, so `GET`, `calendar-multiget`, `calendar-query` and the sync report all present the same view, and the mark travels with `COPY` and `MOVE` because the dead properties do.

* **A scheduling message never carries a mark.** An Outbox `POST` whose body states any access level is refused `CS:no-access-restrictions` — the recipients' servers keep their own users' privacy.

* **The `ACL` method stores grants and denies in ace order.** RFC 3744 section 8.1's method parses `DAV:ace` grants and denies of `DAV:read` and `DAV:write` (plus the read-side leaves a grant implies) for `DAV:href` principals and `DAV:authenticated`; a principal the server cannot place or a privilege it does not enforce is refused with the section's preconditions rather than stored. `Dav.Cal.Delegation` consults the list alongside proxy grants, with the reference's traversal rule: within one list the first ace matching the caller and privilege decides, across the levels a denial anywhere refuses — an object-level grant does not tunnel into a calendar its reader cannot enter — a calendar's aces are inherited by its objects while a regular collection's members answer for themselves, and a calendar home takes no list at all, `405` as the reference answers it. A privilege is held through its aggregates (`CALDAV:read-free-busy` through `DAV:read`, everything through `DAV:all`), the section 8.1 preconditions are enforced individually (`no-ace-conflict` for a restated `protected`/`inherited` mark, `no-protected-ace-conflict` for a deny against an administrator, `no-inherited-ace-conflict` for one against the owner, `deny-before-grant` for a deny ahead of a grant), and enforcement reaches every read path: reports drop or `403` refused objects through `disclosed/3`, and both free-busy paths skip an object whose list denies `read-free-busy` — while `CALDAV:calendar-free-busy-set` stored on the Inbox now selects exactly the calendars an Outbox free-busy consults, wherever they sit in the home. `DAV:acl` itself, like `DAV:owner`, answers only where `read-acl` would be granted; `DAV:owner` also gained the reference's shape — inherited by every resource under a home, stated on none of the principals.

* **`GET` on a calendar collection answers the whole calendar** rolled into one `VCALENDAR` (`Dav.Cal.Rollup`, through the `rendered/2` seam): timezones stated once, each member shown as the caller's access level allows, private members left out entirely.

Two rules landed here reach wider than access: the organiser's stored copy states `EMAIL=` beside a canonicalised `urn:` address — the parameter says where mail goes once the address no longer does — and an attendee line with no `PARTSTAT` gains `RSVP=TRUE`, the unanswered invitation recorded as awaiting reply.

The `acl.xml` drive also landed the surrounding RFC 3744 furniture: `DAV:principal-collection-set` stated on every resource (the plug's `:principals` option), `DAV:principal-URL` answering the canonical spelling on an aliased principal, empty-but-present `DAV:alternate-URI-set` and `DAV:group-member-set` on principals, `DAV:group` absent rather than empty, `CALDAV:read-free-busy` in the privilege tree, `DAV:current-user-privilege-set` gaining `CALDAV:schedule` on the scheduling Inbox and Outbox and dropping to the read subtree on the attachment store, and `COPY`/`MOVE` across calendar homes refused `403` outright — compared by the home the path names, so a sharee's move through a view in their own home still lands. The harness gained upstream's `aclItems` verifier, `generate="yes"` fixture bodies (a fresh `UID` per send, which several ACL fixtures rely on to avoid same-calendar UID conflicts), and password checking on every account, the admin included — a wrong password is `401`, not a quieter identity. Four era-drifted fixtures were repaired with intent preserved, each recorded in `FETCHING.md`.

## The splitting model

Apple's recurrence splitting, in `Dav.Cal.Split` (`recurrence-splitting` declared, `calendarserver-recurrence-split` in the `DAV` header). `POST ?action=split&rid=` on a calendar object divides a recurring event at `rid`; `recurrence-splitting.xml` passes in full. The rules the fixtures pin down:

* **The original resource keeps its `UID` and becomes the future.** Its `DTSTART` moves to the first instance at or after `rid`; a `COUNT` rule keeps only what the past did not spend. The past lands in a new resource under a fresh `UID` — or the client's, refused `CS:valid-split` when that `UID` already names anything in the calendar — its rule closed with `UNTIL` one second (one day, for a date event) before the first onward instance, and a rewritten date `DTSTART` drops its redundant `VALUE=DATE`. Every component of both halves carries the same `RELATED-TO;RELTYPE=X-CALENDARSERVER-RECURRENCE-SET` marker, and overrides go to whichever half holds their `RECURRENCE-ID`.

* **The response names the new resource** in a `Split-Component-URL` header over a `204`; `Prefer: return=representation` answers `207` with each half's `ETag`, body and `Schedule-Tag` instead. `If-Match` and `If-Schedule-Tag-Match` gate the split the way they gate a write, answered `412`.

* **The preconditions**: no `rid`, or one that does not spell a moment, is `CALDAV:valid-rid-parameter`; a non-recurring event, a `rid` whose form does not match the event's (floating against UTC), or a cut with nothing on one side is `CS:valid-split`.

* **A scheduled split reaches every attendee.** `SEQUENCE` rises on both halves; each attendee's stored copy is divided by the same cut — their own alarms and answers intact on both halves, which a fresh invitation could never preserve — the halves get fresh `Schedule-Tag`s, and both halves land in each attendee's Inbox as `REQUEST` messages.

The harness gained multi-variable `grabelement` (the nth matching element's text into the nth variable), which the splitting suites use to take both multistatus hrefs from one response.

## Small features from the same drive

* `CS:getctag` (`ctag` declared): already implemented as the sync token's twin; `ctag.xml` needed the harness's `propfindItems` to honour its `only` argument, and one Apple quirk — a `MOVE` whose source is gone and whose destination is taken answers `403` for the destination rather than `404` for the source.

* RFC 6764 `/.well-known/caldav` (`well-known`): answers `301` to the service before any credentials — discovery happens pre-auth, so no challenge stands in front of it.

* Apple's `Brief: t` header (`brief`): the pre-RFC 7240 spelling of `return=minimal`, folded into the same preference.

* RFC 5842's `DAV:resource-id` (`resource-id`): the identity that names the resource itself wherever it is bound, via the `c:Dav.Web.Store.resource_id/2` seam — a principal answers its stable uid, everything else what the store mints and keeps across `MOVE`.

* Apple's `X-CALENDARSERVER-MASK-UID` on free-busy `POST` (`maskuid`): the event being rescheduled is left out of its own conflict check — but only the asker's own meeting hides: the masked event's organizer must be the request's, or an organizer-less event must sit in the request organizer's own calendar. Landing it also aligned iCalendar line folding with the reference (74 octets on the first line, not 75) — the fixtures compare folded bytes.

## Preferences and the extended query grammar

Two smaller features landed after the auto-scheduling drive, both full passes:

* RFC 7240 `Prefer`, in `Dav.Web.Plug` (`prefer`, `prefer-minimal`, `prefer-noroot`, `prefer-representation` declared; `prefer.xml` 28/28). `return=minimal` trims the `404` propstats from `PROPFIND` and report answers and turns an all-successful `PROPPATCH` into a bare `200`; `depth-noroot` drops the target's own response from a `Depth: 1` listing; `return=representation` answers a `PUT` with what was actually stored — hooks' rewrites included — plus `Content-Location`, and a failed conditional write answers with the copy that won, sparing the client the `GET` either way.

* The extended query grammar (`query-extended`, with `calendar-query-extended` advertised): `test="anyof"` on `comp-filter`/`prop-filter` in `Dav.Cal.Filter`, and `match-type` (`equals`, `starts-with`, `ends-with`, `contains`) on `text-match`. One `reports.xml` suite is cited incidental: its two verify variants assume either a single combined events-and-tasks calendar or the full `split-calendars` feature, and the harness's split layout without the splitting behaviour fits neither.

## The attachments model

Apple's managed attachments (`Dav.Cal.Attachments`, declaring `calendar-managed-attachments`), plus RFC 5995 `POST ;add-member` (`add-member` declared, `DAV:add-member` advertised on calendars, `add-member.xml` a full pass). The core file `managed-attachments.xml` and `managed-attachments-recurrence.xml` pass in full; the rules that took reading the fixtures to learn:

* **A managed `ATTACH` property belongs to the server, not the client.** `POST ?action=attachment-add|update|remove` stores the file under the owner's `dropbox` and writes an `ATTACH;MANAGED-ID=...;FILENAME=...;FMTTYPE=...;SIZE=...` into the targeted components. On every later `PUT`, the canonical form is restored from the stored file — mangled parameters, a swapped URL, or a dropped `MANAGED-ID` on a value that names the home's own file are all corrected in place.

* **Files are per-event copies, reference-counted by the event bodies.** Storage is `dropbox/<uid>/<filename>`, and the event bodies are the id register — an id is valid exactly while some event carries it. A `PUT` reusing an id another event in the home carries keeps the id but gets its own copy of the file under its own URL, so each reference lives and dies alone: an update elsewhere or a deleted event only takes a file with it when it held the last reference. Collection is a sweep after every write and delete.

* **Somebody else's id is stripped, a made-up one is refused.** A `PUT` carrying a `MANAGED-ID` no event in the writer's home carries keeps the `ATTACH` as a plain URL — the parameter is deleted after storing — when the id is at least shaped like a real one; anything else is `CALDAV:valid-managed-id`. A `managed-id` parameter on `attachment-add` is `CALDAV:valid-managed-id-parameter`, and so is a `rid` — the reference attaches to the whole event, never to an instance. The sixth attachment is `CALDAV:max-attachments`.

* **The attachment area answers `403`, not `404`.** A `GET` under someone else's `dropbox`, or for a path that is not there, is refused with `DAV:need-privileges` rather than confirming what exists — via the `readable/2` hook seam.

* **Attachments travel with the schedule.** An attachment `POST` on a scheduled event raises `SEQUENCE` and runs the written-hook fan-out, so the new version is delivered to the attendees — whose copies carry the organizer's `ATTACH` verbatim, id included. An attendee may `GET` the organizer's file for as long as the organizer's copy names them an attendee; their own `POST`s are refused with `CALDAV:valid-attachment-add`/`-update`/`-remove`, and a `PUT` that edits the `ATTACH` set on their copy fails silently — the properties are restored from the copy the write replaced. A dropped attendee's `CANCEL` carries `generateCancel`'s `seq + 1`, unless somebody was asked this round or the client renumbered its own save — either already raised it.

* **A sharee acts in the sharer's home.** Attachment `POST`s through a sharee's view are settled onto the origin path first (`c:Dav.Web.Store.origin/2`), so files land in the sharer's dropbox under the sharer's URLs. A read-write sharee manages attachments; a read-only sharee is refused `DAV:need-privileges`; and sharees read the files of any event in a calendar shared to them — `Dav.Cal.Sharing.granted_on/2` is the public seam that answers what access a caller holds on an original.

* **The attachment area is the server's to write.** A client `PUT`, `MKCOL` or `MKCALENDAR` under a `dropbox` is refused — `403` flat, `405` inside an existing attachment directory — via the `creatable/3` hook seam, and `PROPFIND` of a refused path answers `403` `DAV:need-privileges` like the `GET` path rather than confirming what exists. Principals advertise `CS:dropbox-home-URL`.

* The harness's `grabcalparameter` grab was an unimplemented stub until this drive — `$managed_id1:` never bound, so every fixture that carried an id between requests either skipped or failed. If a suite family fails uniformly on "unresolved" variables, check the grab implementations before the server.

## The synchronisation model

RFC 6578 collection synchronisation, in `Dav.Web.Sync` and the store seams `c:Dav.Web.Store.sync_token/2` and `c:Dav.Web.Store.changes/4`. Driven after the main drive closed, against `sync-report.xml` (100/100), `sharing-sync.xml` and `sharing-notification-sync.xml` (both full passes), with both `sync-report` and `sync-report-home` declared.

* Tokens are `data:,<revision>` on the store's write clock. Calendars, the scheduling Inbox, notification collections and the calendar home are synchronised; the container above the homes is not, and advertises neither the report nor the property. `DAV:supported-report-set` is filtered per resource on the same condition.

* `DAV:sync-level` `1` reports a collection's own members, `infinity` everything beneath; the reference server also accepts the pre-RFC spelling `infinite`, and a request without the element reads the `Depth` header instead. A home at level 1 reports which child collections changed — a property change counts, so `PROPPATCH` stamps the resource (and, through a share link, the origin, so both parties' homes move).

* An initial synchronisation reports the collection itself along with its members, and the collection answers `DAV:getetag` (the version its token names) and `DAV:getcontenttype` the way the reference server's collections do. A difference reports only the delta. Deletions come back as bare `404` responses — including a member created *and* deleted since the token — but a collection deleted and remade answers only for its new life, and the reference server's attachment `dropbox` is answered `404` in an initial home report to say it is not synchronised here.

* Two refusals: a token the store never issued (or `null`) is `DAV:valid-sync-token`, and a `DAV:limit` is `DAV:number-of-matches-within-limits` since truncation is never silent. A third, subtler one: an `infinity` home difference across a share link that *appeared* since the token is `DAV:valid-sync-token` — the linked collection's history is not expressible against the old view of the home, so the client is sent back for an initial synchronisation. The link's *birth* gates this, not its last change.

* Sync propstats answer from live properties, then the store's dead properties, then the hook-contributed ones — `CALDAV:schedule-calendar-transp` defaults to `opaque` through the scheduling hook exactly as in `PROPFIND`. `Prefer: return=minimal` drops the `404` propstats.

* The harness grew the reference deployment's remaining home members — a `tasks` calendar (declared `VTODO`-only and transparent, so free-busy and default-calendar selection skip it; scheduling's delivery fallback now requires an event-capable calendar), a `freebusy` resource, and the `dropbox`. It also grew `basename($var:)` grab variables, bracketed `[-,...]` href lists (`-` is the request URI), summed multi-value counts, and duplicate-slash collapse in expected hrefs.

## Hook seams added for conformance

Optional callbacks on `Dav.Web.Hook`, each added when a behaviour had no seam to live in: `patchable/3` (semantic PROPPATCH validation — free-busy-set hrefs must exist, the default-calendar URL must be an owned calendar), `removable/3` (delete authorisation beyond access control), `relocated/3` (repairing pointers after a MOVE), `inherited/3` (property floors for shared views), `readable/2` (read refusals for private material — the attachment area, somebody else's private event), `creatable/3` (creation refusals for server-owned parts of the tree), `disclosed/3` (body filtering at read time — the access levels), `rendered/2` (a collection presented as a document — the rolled-up calendar). On `Dav.Web.Store`: `unattended?/2` (which addresses are auto-managed), `sync_token/2` and `changes/4` (RFC 6578 change history).

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
