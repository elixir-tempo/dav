# TODO

Open items found while driving CalDAV conformance. Each entry says where the evidence came from, so it can be reproduced without re-deriving it, and what has already been measured — several are things that were built, measured negative, and reverted rather than left half-done.

Resolved items are deleted, not struck through. What is here is what is still true.

## CalDAVTester (Apple)

* **`implicit/copymove/put-restrictions` expects addresses the suite elsewhere requires to be normalised.** Its expected files carry `ATTENDEE:mailto:user01@example.com` with no `EMAIL` parameter. `implicit/scenario1/simple` sends exactly that same `mailto:` form and expects `urn:x-uid:…` back with `EMAIL=` added — the server normalising, deliberately. Both cannot be right, and the copymove files have no `EMAIL` anywhere, which is what you would expect of fixtures written before normalisation existed.

* **The `EMAIL parameter` feature is declared but never used.** `serverinfo.xml` defines it as "Server normalizes cuaddress and adds EMAIL parameter", and it appears in zero `<require-feature>` blocks across the CalDAV scripts. It is the natural gate for the item above, so declaring it changes nothing today.

* **The `X-` allowlist the suites assume is in no vendored file.** `implicitxdash.xml` requires the server to carry `X-TEST-ALL-PROP1`, `X-TEST-ORGANIZER-PARAM1` and friends across scheduling while dropping `X-FOO`, `X-BAR` and `X-TEST-ORGANIZER-PROP2`. The names appear only in fixtures — `grep X-TEST serverinfo.xml` finds nothing — so the allowlist lives in a server config that ships separately. Read out of the fixtures and configured as `Dav.Web.Plug`'s `:extensions` option; recorded here because the next person will look for it in `serverinfo.xml` and not find it. The calendar-user-proxy setup the `sharing-*` suites assume is in the same position.

## Ours — investigated, parked with the evidence

* **A withdrawn occurrence should travel as a `CANCEL`, and the model is incomplete.** RFC 5546 section 3.2.5 says an instance the organiser removes is withdrawn by a `CANCEL` naming it, not by an `EXDATE` the recipient has to interpret. Two suites confirm it: `implicitscenario3` "First cancel" removes an instance with `EXDATE` and waits for **two** Inbox messages — a `REQUEST` for the series and a `CANCEL` for the instance — and `implicitcancels` "Recurring - remove - twice" expects the attendee's copy to hold a cancelled override and no `EXDATE` at all.

  Four pieces are needed together: send a `CANCEL` built from the master for each newly added `EXDATE`; withhold that exclusion from the recipient's copy; materialise the cancelled override in a copy that holds the series only as a rule; and stop treating a cancelled occurrence as an answer, since otherwise the attendee's next `PUT` looks like they withdrew it. Measured against the suite: the pieces alone are −6, −2 and −4; all four together are −1, with +2 in `implicitcancels`.

  What is missing is the condition under which the exclusion *does* belong in the recipient's copy. Three tests want it there — `implicitbadclients` "Client drops a master instance" 17, `implicitfreebusy` "Organizer invites auto-accept Attendee and checks freebusy" 7, and `impliciterrors` "Recurrence expand with expand EXDATE" 9 — and the last of those waits for **one** Inbox message where `implicitscenario3` waits for two, so the server is expected to tell them apart. "Newly added versus pre-existing exclusion" is not the distinction: gating on it measured the same −1. Until that condition is named, shipping the model would make three correct behaviours wrong, which is why it is parked rather than committed.

* **13 failures cannot pass on any server.** 12 in `implicitcopymove` compare against pre-normalisation addresses (above); 1 in `impliciterrors` carries a hard-coded 2005–2009 date. Counted by matching `mailto:` on the expected side against `urn:x-uid:` on ours, and by `~r/200[5-9]\d{4}T/` over the failure text. The date-based group was 14 and is now 1 — the rest were repaired in the vendored fixtures, see `rfc/conformance/caldavtester/FETCHING.md`. Worth knowing before spending time on those files again.

* **`SEQUENCE` is raised for outgoing messages but not for a `CANCEL`.** RFC 5546 section 3.2.5 requires a cancellation to carry a raised `SEQUENCE`, so an attendee can tell it is newer than the invitation it withdraws. The machinery is all there — `sequenced/2`, `bumped/2`, `raise_sequence/2` — and `restated/2` writes the result into the organiser's stored copy, so ordinary edits are already numbered. Applying `bumped/2` to a `CANCEL`'s components measured −1 with no gain, which says the attendee's cancelled copy is not built from the message's `SEQUENCE` at all. **That is the thing to find** before trying again: where the attendee's copy comes from on a cancellation. 29 tests across 13 files turn on it.

* **A sharee may change an organiser's event.** `implicitsharing` "Organizer shared calendar" tests 7–9 write another user's meeting through a share and expect `403`; we accept them. The rule that fits the fixtures: a sharee who is neither the organiser nor an attendee may keep their own alarms and transparency on the event and nothing else — they may not rename it, nor answer on an attendee's behalf. Built and measured: scoped to any event it costs −15 (a read-write sharee may legitimately edit a *non*-scheduling event, which `sharing-peruser-data` checks); scoped to events carrying an `ORGANIZER` it is net 0 but turns tests 6 and 14 into false refusals, because an alarm-only change compares as different. The missing piece is the per-user split — the server has no definition of its own, only the test store's `~w(TRANSP)` and `~w(VALARM)`. Reverted; the rule is right and the comparison is not.

* **`MOVE` and `COPY` report nothing to the hooks.** `carry_out/4` calls the store and returns; only `PUT` and `DELETE` reach `written/5` and `withdrawn/4`. So an invitation carried from a plain collection into a calendar is never sent, and one carried out is never withdrawn — which RFC 6638 section 3 makes a scheduling event, since a scheduling object resource is precisely one *in a calendar collection*.

  Reporting a relocation as a write at the destination and a withdrawal at the source was built and measured three ways: unconditionally (−5), skipping same-collection renames (−4), and reporting only a genuine crossing — arriving where it was not already a scheduling object, leaving for somewhere it will not be (−3). The last is the right shape and still **fixes nothing**: comparing the failing sets before and after, the same tests fail with different reasons ("no matching resource in collection" becomes "1 items, expected 0") and three more join them. The messages are being sent; they are the wrong ones. Whatever `implicitcopymove` wants on a crossing, it is not simply the `PUT` path replayed at the destination — that is the thing to work out before trying a fourth time.

* **A newly added override asks an attendee who has already answered.** `restore_participation/2` matches the stored copy by `RECURRENCE-ID`. An override the organiser has just created has nothing stored of its own, so `known` is empty and `participating/3` falls to `answered_or_asked/3`, which puts the question again — `NEEDS-ACTION;RSVP=TRUE` — to somebody who answered the series. Traced end to end: `apply_reply/4` *does* apply the decline (the master is stored `DECLINED`), `restore_participation/2` *does* keep it for the master, and only the new overrides are reset. `RECORD` shows exactly that: `master=DECLINED, 20270102=NEEDS-ACTION, 20270103=NEEDS-ACTION`.

  Falling back to the series answer when the occurrence has none is the obvious fix and measures **+3 / −2**. Narrowed further — inherit only when the override leaves the instance where the rule put it (`RECURRENCE-ID == DTSTART`), since one that *moves* an occurrence is a new invitation — it is still **+3 / −2**, net +1. The 3 are `implicitrecur2` "Organizer invites other Attendee to one instance only" 2, 7 and 11, which are plainly right. The 2 are `implicitattendeedelete` "Recurring with master" 29 and — the reason it is not committed — `impliciterrors` "Organizer TRANSP leakage" 7, which this session had just *fixed*, and which comes back failing on `SEQUENCE` and `SUMMARY` rather than on participation. Something about keeping the answer suppresses a re-delivery the attendee needs. Reverted until that is understood; the diff above is the whole of what is known.

  Fixed on the way, and kept: a newly added override now inherits the series' `TRANSP`, and `restore/2` drops a stale `RSVP=TRUE` once a participation has been answered, mirroring `retold/4`.

## Harness — the vendored `serverinfo.xml`

`scripts/server/serverinfo.xml` is already vendored, and `Dav.CalDAVTester.ServerInfo` reads all 71 substitutions from it. Two things about the rest of that file are worth writing down, because they pull in opposite directions.

* **Its `<feature>` list must *not* be adopted.** Upstream declares 84 features — the set calendarserver implements. `Dav.CalDAVTester.Features.@declared` lists the dozen this server implements, and that difference is the whole point: `<require-feature>` gating is only meaningful while the declaration is a claim about *this* server. Wiring the vendored list through would look like finishing the job and would in fact run suites we cannot pass, then report their failures as ours. Leave `@declared` hand-maintained, one entry per implemented feature, each saying which module implements it.

* **The account count is now read from it.** `<repeat count="40">` plus the named accounts `ServerInfo` gives numbered slots to is counted from the `$useridN:` keys the file produced, rather than restated as `@people 41` in `runner.ex`. Derives 41, as before; the two numbers can no longer drift.

* **`WAITDELETEALL`'s count is deliberately not asserted, and that is not an oversight.** Upstream refuses to empty until the count matches, re-checking for thirty seconds; this harness answers immediately, so refusing cascades — 222 failures, none about the thing they report. Asserting the count *and* emptying anyway looks like the obvious fix and was tried: it surfaces 102 mismatches. Narrowing to a surplus only — on the reasoning that no amount of waiting removes a message — still surfaces 60. Both are unattributable. Run a suite on its own and its counts are exact, so a surplus is a *previous* suite's residue rather than over-delivery in this one; upstream never sees it because its wait converges and its empty always lands. Reverted, and recorded at the call site. Re-deriving this costs an afternoon.

* **The remaining knobs are inert here, and are listed so nobody looks for them.** Three values are declared in the vendored file and unused:

  | serverinfo | why it is unused |
  | --- | --- |
  | `<waitcount>120</waitcount>` | the poll limit; every `WAIT` collapses to one check |
  | `<waitdelay>0.25</waitdelay>` | the gap between polls; there are no polls |
  | `<waitsuccess>30</waitsuccess>` | `wait-for-success`, on 78 requests, retries until a request passes — deterministic in-process, so a retry returns the same answer |

  All three describe waiting for a server doing work in the background. This one is called in-process and synchronously: nothing can arrive between two calls. They matter only if the harness ever grows an asynchronous mode, and are listed so the next person does not go looking for where the values are read.

