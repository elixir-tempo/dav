# Why each known-failing area fails, and on whose authority it matters.
#
# Three classes, in priority order:
#
#   :rfc        — behaviour an RFC requires. These are defects, full stop,
#                 and the queue to drive to zero first.
#
#   :apple      — CalendarServer/Apple behaviour beyond the RFCs: sharing,
#                 per-user data, auto-accept, X- allowlists, repair of bad
#                 client data. Reasonable, and what Apple Calendar expects —
#                 the second queue, for the interop phase.
#
#   :incidental — expectations that cannot be met on principle: fixtures
#                 that contradict each other or depend on deployment facts
#                 the vendored corpus does not carry. Skip-listed, cited.
#
# Keys are {file, suite}; a file alone classifies every suite in it not
# named more specifically. Unlisted failures report as :unclassified so
# new ones are triaged rather than silently binned.
%{
  # --- apple: the open auto-schedule tail --------------------------------
  # Room auto-accept (RFC 6638 with CalendarServer's answering modes)
  # landed with the `auto-accept` feature; these files' remaining
  # failures are fine-detail differences still being worked — sequence
  # propagation to kept copies, cancel bookkeeping on auto-managed
  # calendars, and the accept-if-free delegate flow. See CONFORMANCE.md.
  {"implicitauto2.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},
  {"implicitauto3.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},
  {"implicitauto4.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},
  {"implicitauto9.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},
  {"implicitauto10.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},
  {"implicitautopast.xml", nil} => {:apple, "auto-schedule tail; see CONFORMANCE.md"},

  # --- incidental: cannot pass as vendored -------------------------------
  {"reports.xml", "basic query reports"} =>
    {:incidental,
     "test 18a's two verify variants assume either one combined events-and-tasks calendar or the full split-calendars feature; the harness provisions the split layout (a separate tasks calendar) without the splitting behaviour, so neither variant's href set fits"},
  {"implicitcopymove.xml", "PUT UID restrictions - ORGANIZER"} =>
    {:incidental, "expected files predate address canonicalisation; see CONFORMANCE.md"},
  {"implicitcopymove.xml", "PUT UID restrictions - ATTENDEE"} =>
    {:incidental, "expected files predate address canonicalisation; see CONFORMANCE.md"},
  {"implicitcopymove.xml", "MOVE to other calendar - ATTENDEE"} =>
    {:incidental,
     "expects the attendee copy removed after cancel; the current reference marks it cancelled (itip.py processCancel) — earlier-era behaviour"},
  {"implicitcopymove.xml", "MOVE from/to collection - ORGANIZER"} =>
    {:incidental,
     "expects the attendee copy removed after cancel; the current reference marks it cancelled (itip.py processCancel) — earlier-era behaviour"},
  {"implicitcopymove.xml", "MOVE to calendar with overwrite - ORGANIZER"} =>
    {:incidental,
     "expects the attendee copy removed after cancel; the current reference marks it cancelled (itip.py processCancel) — earlier-era behaviour"},
  {"implicitcopymove.xml", "COPY to calendar with overwrite - ORGANIZER"} =>
    {:incidental,
     "expects the attendee copy removed after cancel; the current reference marks it cancelled (itip.py processCancel) — earlier-era behaviour"},
  {"copymove.xml", "MOVE"} =>
    {:incidental,
     "test 5 expects a cross-calendar overwrite-move refused under the no-duplicate-uids posture; implicitcopymove requires the opposite posture, and this deployment takes that one"},
  {"servertoserverincoming.xml", "POST free-busy"} =>
    {:incidental,
     "test 2 posts the byte-identical one-attendee request as test 1 but expects a second attendee's busy time — the discriminator is not in the vendored fixture"},
  {"servertoserverincoming.xml", "POST Errors"} =>
    {:incidental,
     "identical requests, contradictory expectations; discriminators are connection-level"},
  {"implicitdeletecalendar.xml", "Multiple Nested Calendars Delete"} =>
    {:incidental,
     "sibling fixtures expect SEQUENCE:2 and none from one DELETE; see CONFORMANCE.md"},
  {"bad-ical.xml", nil} => {:incidental, "the vendored fixture directory is empty upstream"},
  {"schedulenomore.xml", nil} => {:incidental, "the SCHEDULE method was never standardised"},

  # --- apple: extensions and conventions beyond the RFCs -----------------
  {"sharing-calendars.xml", nil} => {:apple, "calendarserver-sharing extension"},
  {"sharing-direct.xml", nil} => {:apple, "calendarserver-sharing extension"},
  {"sharing-errors.xml", nil} => {:apple, "calendarserver-sharing extension"},
  {"sharing-peruser-data.xml", nil} => {:apple, "per-user data in shared calendars"},
  {"sharing-peruser-properties.xml", nil} => {:apple, "per-user properties in shared calendars"},
  {"sharing-replies.xml", nil} => {:apple, "calendarserver-sharing extension"},
  {"sharing-unshare.xml", nil} => {:apple, "calendarserver-sharing extension"},
  {"implicitsharing.xml", nil} => {:apple, "scheduling inside shared calendars"},
  {"implicitprivateevents.xml", nil} => {:apple, "X-CALENDARSERVER-ACCESS"},
  {"implicitpublicproperties.xml", nil} => {:apple, "X-CALENDARSERVER-ACCESS"},
  {"implicitxdash.xml", nil} => {:apple, "deployment X- property allowlist"},
  {"implicitimip.xml", nil} => {:apple, "iMIP bridging as CalendarServer wires it"},
  {"implicitbadclients.xml", nil} => {:apple, "server-side repair of damaged client data"},
  {"implicitcompatibility.xml", nil} => {:apple, "acceptance of structurally broken objects"},
  {"implicittodo.xml", "Client removing properties fix"} => {:apple, "server-side repair"},
  {"implicitbatchrefresh.xml", nil} =>
    {:apple, "attendee refresh batching; RFC 6638 does not require refreshes"},
  {"implicitattendeedelete.xml", nil} =>
    {:apple, "hidden-instance model for declined-by-delete copies"},
  {"implicitfreebusy.xml", nil} => {:apple, "resource auto-accept scheduling"},
  {"implicitdefaultcalendar.xml", nil} =>
    {:apple, "default-calendar provisioning and protection policy"},
  {"implicitcalendartransp.xml", "New Calendar - free-busy-set compatibility"} =>
    {:apple, "legacy CS:calendar-free-busy-set compatibility"},
  {"scheduleprops.xml", "free-busy-set"} => {:apple, "legacy CS:calendar-free-busy-set"},
  {"scheduleimplicit-compatability.xml", nil} =>
    {:apple, "explicit-to-implicit transition behaviour"},
  {"servertoserverincoming.xml", nil} => {:apple, "iSchedule is a draft, never an RFC"},
  {"servertoserveroutgoing.xml", nil} => {:apple, "iSchedule is a draft, never an RFC"},
  {"timezones.xml", "Timezone cache - aliases"} => {:apple, "timezone service aliasing"},
  {"attachments.xml", "Too many"} => {:apple, "deployment attachment-count limit"},
  {"duplicate_uids.xml", nil} =>
    {:apple, "cross-calendar UID refusal for non-scheduling objects"},
  {"put.xml", "PUT with relaxed parsing"} => {:apple, "acceptance of malformed durations"},
  {"implicitscenario1.xml", "Alarms"} => {:apple, "per-user alarm filtering"},
  {"implicitscenario1.xml", "Recurring Alarms"} => {:apple, "per-user alarm filtering"},
  {"implicitscenario1.xml", "No X- properties"} => {:apple, "deployment X- property allowlist"},
  {"implicitscenario1.xml", "Per-Attendee X- properties"} =>
    {:apple, "deployment X- property allowlist"},

  # --- rfc: required behaviour ------------------------------------------
  {"current-user-principal.xml", nil} => {:rfc, "RFC 5397; HTTP authentication"},
  {"ical-client.xml", nil} => {:rfc, "HTTP authentication on principal discovery"},
  {"errors.xml", nil} => {:rfc, "RFC 4791 section 5.3.2 PUT preconditions"},
  {"mkcalendar.xml", nil} => {:rfc, "RFC 4791 section 5.3.1 MKCALENDAR"},
  {"proppatch.xml", nil} => {:rfc, "RFC 4918 section 4.3 language information"},
  {"nonascii.xml", nil} => {:rfc, "RFC 6638 scheduling with UTF-8 data"},
  {"schedulepost.xml", nil} => {:rfc, "RFC 6638 section 4 free-busy on the Outbox"},
  {"implicitcancels.xml", nil} => {:rfc, "RFC 5546 section 3.2.5 CANCEL semantics"},
  {"implicitcopymove.xml", nil} =>
    {:rfc, "RFC 4791 section 5.3.2 on COPY/MOVE; RFC 6638 section 3.1"},
  {"impliciterrors.xml", nil} => {:rfc, "RFC 6638 section 3.2 preconditions"},
  {"implicitpartstatchange.xml", nil} => {:rfc, "RFC 6638 reply processing"},
  {"implicitrecur1.xml", nil} => {:rfc, "RFC 5546/6638 recurrence scheduling"},
  {"implicitrecur2.xml", nil} => {:rfc, "RFC 5546/6638 recurrence scheduling"},
  {"implicitscenario1.xml", nil} => {:rfc, "RFC 6638 implicit scheduling basics"},
  {"implicitscenario3.xml", nil} => {:rfc, "RFC 5546 section 3.2.5 instance cancellation"},
  {"implicitscheduleagent.xml", nil} => {:rfc, "RFC 6638 section 7.1 SCHEDULE-AGENT"},
  {"implicitscheduletag.xml", nil} => {:rfc, "RFC 6638 section 3.2.10 Schedule-Tag"},
  {"implicitsecurity.xml", nil} => {:rfc, "RFC 6638 section 3.2.2 organizer integrity"},
  {"reports.xml", "limit/expand recurrence in reports"} =>
    {:rfc, "RFC 4791 sections 9.6.5/9.6.6 limit-recurrence-set and expand"},
  {"timezones.xml", "Timezone properties"} => {:rfc, "RFC 7809 timezone properties"},
  {"implicitsequence.xml", nil} => {:rfc, "RFC 5546 section 2.1.4 SEQUENCE"},
  {"implicittimezones.xml", nil} => {:rfc, "RFC 5545 time zone handling in scheduling"},
  {"implicittodo.xml", nil} => {:rfc, "RFC 6638 scheduling for VTODO"},
  {"implicitcalendartransp.xml", nil} => {:rfc, "RFC 6638 section 9.1 schedule-calendar-transp"}
}
