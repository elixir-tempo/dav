# Vendored specifications

Everything needed to implement the WebDAV and CalDAV sibling libraries
described in [the Dav plan](../plans/dav.md), fetched 2026-08-29 from the RFC Editor.

These are reference material. They are **not** part of the published
package — `mix.exs` ships `lib`, `mix.exs`, `README*`, `CHANGELOG*` and
`LICENSE*` only.

## How to read this stack

Each layer is a strict extension of the one below, which is why none of
them can be skipped:

```
HTTP                    RFC 9110/9111/9112
  └── WebDAV            RFC 4918   methods, properties, collections, 207
        └── REPORT      RFC 3253   the extension point everything hangs off
              └── CalDAV      RFC 4791   calendar collections and queries
                    └── Scheduling  RFC 6638   iTIP over CalDAV
```

`REPORT` is worth singling out: it is defined by the *versioning*
extensions, not by WebDAV itself, and every CalDAV query is one. A
WebDAV implementation that omits it cannot host CalDAV.

## HTTP

| RFC | Status | Errata (verified) | What it is |
| --- | --- | --- | --- |
| [9110](http/rfc9110.txt) | Internet Standard | 12 (6) | HTTP Semantics |
| [9111](http/rfc9111.txt) | Internet Standard | 2 (0) | HTTP Caching |
| [9112](http/rfc9112.txt) | Internet Standard | 4 (2) | HTTP/1.1 |
| [9931](http/rfc9931.txt) | Proposed Standard | — | Security Considerations for Optimistic Protocol Transitions (updates 9112) |
| [8615](http/rfc8615.txt) | Proposed Standard | — | Well-Known URIs |
| [8996](http/rfc8996.txt) | Best Current Practice | 3 (2) | Deprecating TLS 1.0 and TLS 1.1 (updates CalDAV) |
| [7240](http/rfc7240.txt) | Proposed Standard | 6 (2) | Prefer Header for HTTP |
| [3339](http/rfc3339.txt) | Proposed Standard | 7 (4) | Date and Time on the Internet |
| [9557](http/rfc9557.txt) | Proposed Standard | 1 (0) | Timestamps with Additional Information (updates 3339) |

## WebDAV

| RFC | Status | Errata (verified) | What it is |
| --- | --- | --- | --- |
| [4918](webdav/rfc4918.txt) | Proposed Standard | 9 (3) | HTTP Extensions for WebDAV -- the base |
| [3253](webdav/rfc3253.txt) | Proposed Standard | 1 (1) | Versioning Extensions -- defines REPORT |
| [3744](webdav/rfc3744.txt) | Proposed Standard | 1 (1) | WebDAV Access Control Protocol |
| [5689](webdav/rfc5689.txt) | Proposed Standard | — | Extended MKCOL |
| [6578](webdav/rfc6578.txt) | Proposed Standard | — | Collection Synchronization |
| [5397](webdav/rfc5397.txt) | Proposed Standard | — | WebDAV Current Principal Extension |
| [3648](webdav/rfc3648.txt) | Proposed Standard | — | Ordered Collections Protocol |
| [4331](webdav/rfc4331.txt) | Proposed Standard | — | Quota and Size Properties |
| [5323](webdav/rfc5323.txt) | Proposed Standard | — | WebDAV SEARCH |
| [5842](webdav/rfc5842.txt) | Experimental | — | Binding Extensions (BIND) -- experimental |
| [4437](webdav/rfc4437.txt) | Experimental | — | Redirect Reference Resources -- experimental |
| [8144](webdav/rfc8144.txt) | Proposed Standard | — | Use of the Prefer Header Field in WebDAV |

## CalDAV

| RFC | Status | Errata (verified) | What it is |
| --- | --- | --- | --- |
| [4791](caldav/rfc4791.txt) | Proposed Standard | 24 (17) | Calendaring Extensions to WebDAV (CalDAV) |
| [6638](caldav/rfc6638.txt) | Proposed Standard | — | Scheduling Extensions to CalDAV |
| [6764](caldav/rfc6764.txt) | Proposed Standard | — | Locating Services for CalDAV and CardDAV |
| [7809](caldav/rfc7809.txt) | Proposed Standard | — | CalDAV Time Zones by Reference |
| [7953](caldav/rfc7953.txt) | Proposed Standard | 1 (1) | Calendar Availability (VAVAILABILITY) |
| [6352](caldav/rfc6352.txt) | Proposed Standard | 2 (1) | CardDAV -- the sibling protocol |

## iCalendar

The object format CalDAV moves around. Correct time-range queries need
recurrence expansion, which is 5545 plus 7529 — and the family already
has that through Tempo.

| RFC | Status | Errata (verified) | What it is |
| --- | --- | --- | --- |
| [5545](icalendar/rfc5545.txt) | Proposed Standard | 39 (22) | iCalendar core object specification |
| [5546](icalendar/rfc5546.txt) | Proposed Standard | 4 (3) | iTIP -- Transport-Independent Interoperability Protocol |
| [6047](icalendar/rfc6047.txt) | Proposed Standard | 1 (1) | iMIP -- Message-Based Interoperability Protocol |
| [6868](icalendar/rfc6868.txt) | Proposed Standard | 2 (1) | Parameter Value Encoding in iCalendar and vCard |
| [7986](icalendar/rfc7986.txt) | Proposed Standard | 1 (0) | New Properties for iCalendar |
| [7529](icalendar/rfc7529.txt) | Proposed Standard | — | Non-Gregorian Recurrence Rules |
| [9074](icalendar/rfc9074.txt) | Proposed Standard | 1 (0) | VALARM Extensions |
| [9073](icalendar/rfc9073.txt) | Proposed Standard | 4 (2) | Event Publishing Extensions |
| [9253](icalendar/rfc9253.txt) | Proposed Standard | 2 (0) | Support for iCalendar Relationships |
| [6321](icalendar/rfc6321.txt) | Proposed Standard | 9 (5) | xCal -- the XML format |
| [7265](icalendar/rfc7265.txt) | Proposed Standard | 3 (0) | jCal -- the JSON format |

## Superseded, kept for context

Not to be implemented against. Present because current documents refer
back to them and because some client behaviour only makes sense in
light of what the earlier text said.

| RFC | Status | Errata (verified) | What it is |
| --- | --- | --- | --- |
| [2518](historic/rfc2518.txt) | Proposed Standard — **obsoleted by 4918** | 1 (1) | WebDAV -- OBSOLETED by 4918 |
| [2445](historic/rfc2445.txt) | Proposed Standard — **obsoleted by 5545** | 11 (9) | iCalendar -- OBSOLETED by 5545 |
| [5785](historic/rfc5785.txt) | Proposed Standard — **obsoleted by 8615** | 2 (1) | Well-Known URIs -- OBSOLETED by 8615 |

## Errata

`errata/` holds one file per RFC that has any, extracted from
<https://www.rfc-editor.org/errata.json> on 2026-08-29. Each entry carries
the original text, the correction, and its status.

**Status is not a formality.** Only *Verified* errata have been
confirmed by the responsible party; *Reported* ones may be wrong, and
*Rejected* ones are wrong. Two counts are worth knowing before starting:

* **RFC 4791 (CalDAV) — 24 errata, 17 verified.**
* **RFC 5545 (iCalendar) — 39 errata, 22 verified.**

An implementation built from the RFC text alone, without reading these,
will be wrong in ways the specification appears to endorse.

## Conformance

See [conformance/README.md](conformance/README.md). Apple's CalDAVTester
is vendored — 226 XML scenarios that describe what real clients expect,
which is often more specific than the RFCs. litmus is documented rather
than vendored, and the reasoning is recorded there.

## Provenance

* Specifications: <https://www.rfc-editor.org/rfc/rfcNNNN.txt>
* Status and supersession: <https://www.rfc-editor.org/rfc-index.xml>
* Errata: <https://www.rfc-editor.org/errata.json>
* CalDAVTester: <https://github.com/apple/ccs-caldavtester>, commit pinned in `conformance/caldavtester/UPSTREAM-COMMIT`

Supersession was taken from the index rather than assumed. Of the
documents considered, only 2518, 2445 and 5785 are obsoleted; the rest
are current, and the *updating* documents 6868, 8144, 8996, 9557 and
9931 were found the same way and would otherwise have been missed.
