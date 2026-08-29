# Upstream items

Defects found while driving CalDAV conformance that belong to another project. Each entry says where the evidence came from, so it can be reproduced without re-deriving it.

## Tempo

* **`Tempo.to_elixir/1` rejects a UTC offset.** A value carrying `Z` converts; one carrying an offset returns `{:error, %Tempo.ConversionError{target: DateTime, reason: nil}}`. Reproduce with `Tempo.to_elixir(~o"2026-06-15T09:00:00+10:00")`. iCalendar `DATE-TIME` values are commonly written with an offset rather than `Z`, so anything reading third-party calendar data hits this. The `reason: nil` is a second, smaller problem — the error does not say what it could not do.

## CalDAVTester (Apple)

* **`depthreports.xml`, `depthreportsacl.xml` and `rscale.xml` hard-code years in their `freeBusy` expectations.** The fixtures they load use `$now.year.1:`, which resolves to the current year, while the expected periods are literal `20060107T010000Z` values. The periods agree on month, day and time and differ only in the year, so these cannot pass on any server. 45 hard-coded values across the three files. Other `freeBusy` suites (`reports.xml`, `floating.xml`, `timezones.xml`, `availability.xml`) parameterise correctly, so this looks like fixtures that were updated and expectations that were not.

* **`implicit/copymove/put-restrictions` expects addresses the suite elsewhere requires to be normalised.** Its expected files carry `ATTENDEE:mailto:user01@example.com` with no `EMAIL` parameter. `implicit/scenario1/simple` sends exactly that same `mailto:` form and expects `urn:x-uid:…` back with `EMAIL=` added — the server normalising, deliberately. Both cannot be right, and the copymove files have no `EMAIL` anywhere, which is what you would expect of fixtures written before normalisation existed.

* **The `EMAIL parameter` feature is declared but never used.** `serverinfo.xml` defines it as "Server normalizes cuaddress and adds EMAIL parameter", and it appears in zero `<require-feature>` blocks across the CalDAV scripts. It is the natural gate for the item above, so declaring it changes nothing today.

* **Server configuration the suites depend on is not vendored.** `implicitxdash.xml` requires the server to carry a specific set of `X-` properties and parameters across scheduling — `X-TEST-ALL-PROP1`, `X-TEST-ORGANIZER-PARAM1` and so on, while `X-FOO`, `X-BAR` and `X-TEST-ORGANIZER-PROP2` are dropped. The names appear only in fixtures, never in `serverinfo.xml`, so the allowlist lives in a server config that ships separately. The same is true of the calendar-user-proxy setup the `sharing-*` suites assume.

## Unclear

* **Custom properties in iCalendar.** Noted as an upstream item to record, but I have no entry for it in this session's findings and do not want to invent one. Candidates it might refer to: the `X-` property and parameter allowlist above, which is now a `:extensions` option on `Dav.Web.Plug` rather than an upstream issue; or `Dav.Cal.ICalendar.write/1` escaping every value, which broke `RRULE` and `VTIMEZONE` and was fixed in this repo earlier. Say which and I will write it up properly.
