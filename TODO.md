# Upstream items

Defects found while driving CalDAV conformance that belong to another project. Each entry says where the evidence came from, so it can be reproduced without re-deriving it.

## Tempo

* **`Tempo.to_elixir/1` rejects a UTC offset.** A value carrying `Z` converts; one carrying an offset returns `{:error, %Tempo.ConversionError{target: DateTime, reason: nil}}`. Reproduce with `Tempo.to_elixir(~o"2026-06-15T09:00:00+10:00")`. iCalendar `DATE-TIME` values are commonly written with an offset rather than `Z`, so anything reading third-party calendar data hits this. The `reason: nil` is a second, smaller problem — the error does not say what it could not do.

* **`Tempo.shift/2` does not accept a duration string.** `Tempo.shift(~o"2026Y6M15DT9H0M0SZ", "-PT30M")` raises `FunctionClauseError`; the caller must run `Tempo.from_iso8601/1` first and pass the result. Parsing handles the negative form correctly — `"-PT30M"` becomes `~o"PT-30M"`, and shifting by it gives `~o"2026Y6M15DT8H30M0SZ"` — so the only gap is that `shift/2` will not do it for you. Every ISO 8601 duration arriving from outside is a string: iCalendar `DURATION`, `TRIGGER` and `REPEAT` values all are, so callers parse at every site. Accepting a binary and parsing it, or raising an error that names the problem rather than a clause mismatch, would remove that.

## CalDAVTester (Apple)

* **`depthreports.xml`, `depthreportsacl.xml` and `rscale.xml` hard-code years in their `freeBusy` expectations.** The fixtures they load use `$now.year.1:`, which resolves to the current year, while the expected periods are literal `20060107T010000Z` values. The periods agree on month, day and time and differ only in the year, so these cannot pass on any server. 45 hard-coded values across the three files. Other `freeBusy` suites (`reports.xml`, `floating.xml`, `timezones.xml`, `availability.xml`) parameterise correctly, so this looks like fixtures that were updated and expectations that were not.

* **`implicit/copymove/put-restrictions` expects addresses the suite elsewhere requires to be normalised.** Its expected files carry `ATTENDEE:mailto:user01@example.com` with no `EMAIL` parameter. `implicit/scenario1/simple` sends exactly that same `mailto:` form and expects `urn:x-uid:…` back with `EMAIL=` added — the server normalising, deliberately. Both cannot be right, and the copymove files have no `EMAIL` anywhere, which is what you would expect of fixtures written before normalisation existed.

* **The `EMAIL parameter` feature is declared but never used.** `serverinfo.xml` defines it as "Server normalizes cuaddress and adds EMAIL parameter", and it appears in zero `<require-feature>` blocks across the CalDAV scripts. It is the natural gate for the item above, so declaring it changes nothing today.

* **Server configuration the suites depend on is not vendored.** `implicitxdash.xml` requires the server to carry a specific set of `X-` properties and parameters across scheduling — `X-TEST-ALL-PROP1`, `X-TEST-ORGANIZER-PARAM1` and so on, while `X-FOO`, `X-BAR` and `X-TEST-ORGANIZER-PROP2` are dropped. The names appear only in fixtures, never in `serverinfo.xml`, so the allowlist lives in a server config that ships separately. The same is true of the calendar-user-proxy setup the `sharing-*` suites assume.

## Ours — investigated, parked with the evidence

* **A withdrawn occurrence should travel as a `CANCEL`, and the model is incomplete.** RFC 5546 section 3.2.5 says an instance the organiser removes is withdrawn by a `CANCEL` naming it, not by an `EXDATE` the recipient has to interpret. Two suites confirm it: `implicitscenario3` "First cancel" removes an instance with `EXDATE` and waits for **two** Inbox messages — a `REQUEST` for the series and a `CANCEL` for the instance — and `implicitcancels` "Recurring - remove - twice" expects the attendee's copy to hold a cancelled override and no `EXDATE` at all.

  Four pieces are needed together: send a `CANCEL` built from the master for each newly added `EXDATE`; withhold that exclusion from the recipient's copy; materialise the cancelled override in a copy that holds the series only as a rule; and stop treating a cancelled occurrence as an answer, since otherwise the attendee's next `PUT` looks like they withdrew it. Measured against the suite: the pieces alone are −6, −2 and −4; all four together are −1, with +2 in `implicitcancels`.

  What is missing is the condition under which the exclusion *does* belong in the recipient's copy. Three tests want it there — `implicitbadclients` "Client drops a master instance" 17, `implicitfreebusy` "Organizer invites auto-accept Attendee and checks freebusy" 7, and `impliciterrors` "Recurrence expand with expand EXDATE" 9 — and the last of those waits for **one** Inbox message where `implicitscenario3` waits for two, so the server is expected to tell them apart. "Newly added versus pre-existing exclusion" is not the distinction: gating on it measured the same −1. Until that condition is named, shipping the model would make three correct behaviours wrong, which is why it is parked rather than committed.

* **26 failures cannot pass on any server.** 12 in `implicitcopymove` compare against pre-normalisation addresses (see above); 14 carry hard-coded 2005–2009 dates — 7 in `depthreports`, 4 in `servertoserverincoming`, and one each in `impliciterrors`, `reports` and `sharing-moves`. Counted by matching `mailto:` on the expected side against `urn:x-uid:` on ours, and by `~r/200[5-9]\d{4}T/` over the failure text. Worth knowing before spending time on those files a third time.

## Unclear

* **Custom properties in iCalendar.** Noted as an upstream item to record, but I have no entry for it in this session's findings and do not want to invent one. Candidates it might refer to: the `X-` property and parameter allowlist above, which is now a `:extensions` option on `Dav.Web.Plug` rather than an upstream issue; or `Dav.Cal.ICalendar.write/1` escaping every value, which broke `RRULE` and `VTIMEZONE` and was fixed in this repo earlier. Say which and I will write it up properly.
