# Dav — one library, three protocols

**Status: being built.** This merges what were two documents, for WebDAV and CalDAV separately, after the decision to host all three protocols in one package. The measurements and RFC statuses here were checked against the vendored specifications in [`rfc/`](../rfc/README.md) rather than remembered.

## Why one library rather than three

The two-library version of this plan proposed a WebDAV package with a public behaviour that a separate CalDAV package would attach to. That was wrong, and its own open questions said so: *"the library shape costs more and is only worth it if something other than CalDAV will use it — which today nothing will."*

Three reasons the single package is right:

* **The seam is internal.** `REPORT` dispatch is still the correct design — it is just a module boundary rather than a published contract, until somebody outside implements against it.

* **Lockstep versioning is a real cost.** Packages that must move together are worse than one that moves. CalDAV work keeps forcing base changes.

* **CardDAV settles it.** Same base, same `REPORT` mechanism, and both Apple and Google speak it. One package hosting three protocols is coherent; three packages with two dependency edges is not.

Namespaces keep the layering honest — `Dav.Web`, `Dav.Cal`, `Dav.Card` — and splitting later is far easier than merging two that have drifted.

## The stack

Each layer is a strict extension of the one below:

```
HTTP                    RFC 9110/9111/9112
  └── WebDAV            RFC 4918   methods, properties, collections, 207
        └── REPORT      RFC 3253   the extension point everything hangs off
              └── CalDAV      RFC 4791
              └── CardDAV     RFC 6352
```

**`REPORT` is not in RFC 4918.** It comes from the versioning extensions, and every CalDAV and CardDAV query is one. An implementation that omits it cannot host either, and the base specification never mentions it — which is exactly how it gets missed.

## Where this came from, and the cheaper answer

Apple Calendar has no plugin model, so publishing Agenda's schedules to it means speaking a protocol its client already understands. That reasoning is sound and it skips a step.

**Tier 1 — an iCalendar subscription feed.** One `GET` returning `text/calendar`. Apple Calendar, Google Calendar and Outlook all subscribe to an ICS URL. No WebDAV, no XML, no method dispatch. Read-only and poll-based, and it answers *"let me see my schedule in my calendar app"* completely. **A day's work.**

**Tier 2 — read-only CalDAV.** Collections a client discovers, `calendar-query` with time-range filtering, `calendar-multiget`, `free-busy-query`, incremental sync. This is the library.

**Tier 3 — read-write with scheduling (RFC 6638).** iTIP invitations, inbox and outbox, `schedule-tag`. Groupware. Out of scope.

**Tier 1 first, and put it in front of a real user**, because it answers the question the rest depends on: whether a subscription is enough, or whether somebody genuinely needs sync. Tier 2 is worth building anyway as a library — but not on the assumption that Agenda needs it.

## What this family brings that a generic server does not

* **Free/busy is derived, not stored.** Agenda's `free/2` is open hours minus what a ledger holds, computed on demand, honouring concurrency, buffers and turnaround. A `free-busy-query` answered from that knows about the ten minutes a room needs between bookings, which no event list contains. **If any part of tier 2 is built first, this is the part** — a server answering only free/busy is far smaller than full CalDAV and is where the advantage is.

* **Recurrence is already solved.** The hardest part of `calendar-query` is time-range filtering, which means expanding `RRULE`, `RDATE`, `EXDATE` and `RECURRENCE-ID` overrides across timezones. Tempo does RFC 5545 recurrence and ISO 8601 repeating intervals already.

## The shape

**A Plug and a behaviour.** The library owns the protocol and owns no storage:

* `Dav.Web.Plug` mounts into any Plug or Phoenix pipeline. **Bandit** serves it; the library knows nothing about the server, and **Req** drives it from the tests.

* `Dav.Web.Store` resolves paths to resources and lists collections. A filesystem, a database, or a scheduling ledger can each be one.

## What can be left out, and what cannot

**Left out — locking.** A server may advertise Class 1 and support no locks, and many clients tolerate it. `LOCK`, `UNLOCK`, lock tokens and the lock half of the `If` header are a large fraction of RFC 4918 and its messiest part. This is the single biggest saving available; take it until a client demands otherwise.

**Left out — dead properties**, initially. If only live properties are served, `PROPPATCH` can be refused. Find out which clients actually complain before building storage for them.

**Cannot be left out:** `REPORT` dispatch; namespaced XML in both directions; `Depth` handling; ETags that genuinely change when content does — clients rely on them for sync correctness, and a stable-when-it-should-not-be ETag causes silent data loss that gets blamed on the client; and collection synchronisation (RFC 6578), without which clients poll whole collections and the server appears not to work.

## XML — decided, and measured

The two-library plan called this the hidden cost and guessed at a SAX parser. Measured instead:

| `:xmerl_scan.string/2` options | External entity |
| --- | --- |
| default | refused |
| `allow_entities: false` | refused |
| `allow_entities: true` | **parsed — local file contents reached the document** |

xmerl was hardened, so **SweetXml is safe** and is what this uses — it is an extraction DSL, and DAV request bodies are small documents of well-known shape, which is what extraction is good at. `Dav.Xml` passes `allow_entities: false` explicitly rather than relying on the default, because the default has changed before and the last row is what a request body from an unauthenticated client could otherwise do.

Responses are built by hand rather than through a serialiser: exactness matters more than convenience, and a missing namespace declaration is indistinguishable from a broken server.

## The honest cost

Tier 1 is a day.

Tier 2 is this library plus an unbounded interop tail — every DAV server in existence carries a layer of client-specific workarounds, and **the specification is about half the job.** The vendored CalDAVTester scenarios are the cheapest available look at the other half, and worth reading before committing to an estimate rather than after.

For a single-person business this is not an increment. It is a roadmap, and it competes with the product.

## What exists, and what is new

| Capability | Where it is | Status |
| --- | --- | --- |
| Recurrence expansion, RFC 5545 and ISO 8601 | Tempo | Built — the hardest CalDAV part |
| Reading `VAVAILABILITY` | `Agenda.from_ical/1` | Built |
| Derived free/busy with buffers and concurrency | `Agenda.free/2` | Built |
| **Namespaced XML, both directions** | `Dav.Xml` | **Built** |
| **`207 Multi-Status` building** | `Dav.Xml.multistatus/1` | **Built** |
| **`PROPFIND` request parsing** | `Dav.Xml.parse_propfind/1` | **Built** |
| **Resources and the storage behaviour** | `Dav.Web.Resource`, `Dav.Web.Store` | **Built** |
| **The Plug, and method dispatch** | `Dav.Web.Plug` | **In progress** |
| **`REPORT` dispatch** | — | **New — the seam the extensions attach to** |
| **Collection synchronisation (RFC 6578)** | — | **New, not optional in practice** |
| **An ICS subscription endpoint (tier 1)** | — | **New, small, and the thing to do first** |
| Locking, Class 2 | — | Deliberately omitted |
| `MKCALENDAR`, `calendar-query`, `free-busy-query` | — | New — `Dav.Cal` |
| CardDAV | — | New — `Dav.Card` |
| Scheduling, iTIP (RFC 6638) | — | Out of scope |
| Being a general-purpose calendar server | — | Out of scope; Radicale and Baïkal exist |

## Where the scope stops

Authentication, authorisation, TLS, quotas and multi-tenancy belong to the host application: the library receives a resolved principal and a store, and speaks the protocol.

This publishes *answers* as calendars. It does not become somewhere people keep their calendars — that is groupware, it is well served already, and competing there would be a decision to stop working on scheduling.

## Open questions

* **Does anyone need sync rather than subscription?** The question tier 1 exists to answer, and it should be asked of a real user rather than guessed.

* **How much does read-only save?** Without writes, `PROPPATCH`, `MKCOL`, `COPY`, `MOVE`, `DELETE` and `PUT` all go, along with most of the `If` header. Possibly more than half of RFC 4918.

* **Is publishing even the right direction?** Agenda currently *reads* availability through `from_ical/1`. It may be that the valuable integration stays inbound.

## Next steps

1. The Plug: method dispatch, `OPTIONS` advertising compliance, `PROPFIND` end to end against a store.
2. `REPORT` dispatch, so the extensions have something to attach to.
3. Tier 1 in Agenda — the ICS feed — in parallel, because it is a day and it answers the question this plan turns on.
