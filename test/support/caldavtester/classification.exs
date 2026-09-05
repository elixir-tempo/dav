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
  # The auto-schedule tail is closed: all six of the room-scheduling
  # files it was filed under pass in full, and nothing is cited here
  # any more. It was never the "two-phase delivery" the group was
  # named for — see CONFORMANCE.md, which traces each part to the
  # line. A new failure in those files reports as unclassified, which
  # is what should happen.

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
  {"bad-json.xml", nil} => {:incidental, "the vendored fixture directory is empty upstream"},
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
  {"implicitcalendartransp.xml", nil} => {:rfc, "RFC 6638 section 9.1 schedule-calendar-transp"},

  # --- apple: the trash's open edges -------------------------------------
  {"trash.xml", "Organizer trashes event"} =>
    {:apple, "recovery re-invites with a raised SEQUENCE; see CONFORMANCE.md"},
  {"trash.xml", "Sharee trashes event"} =>
    {:apple, "a sharee's delete keeps their view, not the owner's full copy"},
  {"trash.xml", "Attendee trashes event, then Organizer splits it"} =>
    {:apple, "splitting an event with a trashed attendee copy"},
  {"trash.xml", "Attachments and trash"} =>
    {:apple, "a trashed event's attachment file is reclaimed; see CONFORMANCE.md"},

  # --- apple: the private-comment tail -----------------------------------
  {"privatecomments.xml", "Change Comment"} =>
    {:apple, "the organiser's copy is restamped when only a comment changed"},
  {"privatecomments.xml", "Remove Comment"} =>
    {:apple, "withdrawing a comment leaves the organiser's line in place"},
  {"privatecomments.xml", "Two Comments"} => {:apple, "two attendees' comments on one instance"},
  {"privatecomments.xml", "Handle old clients"} =>
    {:apple, "a client that sends the organiser's comment back to itself"},
  {"privatecomments.xml", "No duplicates"} =>
    {:apple, "a re-sent identical comment is a second reply"},

  # --- apple: default alarms on shared and delivered copies ---------------
  {"default-alarms.xml", "Shared calendars - initially empty default"} =>
    {:apple, "a sharee's four defaults exist and are empty before they set any"},
  {"default-alarms.xml", "Scheduling"} =>
    {:apple, "a delivered invitation takes the recipient's default alarm"},

  # --- apple: group sharing beyond invitation and withdrawal --------------
  {"sharing-groups.xml", nil} =>
    {:apple, "group-share precedence against direct shares; see CONFORMANCE.md"},
  {"sharing-unshare-groups.xml", nil} =>
    {:apple, "uninviting where group and direct shares overlap; see CONFORMANCE.md"},
  {"sharing-groups-changes.xml", nil} =>
    {:apple, "membership changes propagating to shares; see CONFORMANCE.md"},

  # --- apple: the schedule-changes tail ----------------------------------
  {"implicitschedulechanges.xml", "Organizer Changes"} =>
    {:apple, "a changed DTEND is not named among the changed properties"},
  {"implicitschedulechanges.xml", "Private Comment"} =>
    {:apple, "an ATTENDEE changed by a comment round is not named"},
  {"implicitschedulechanges.xml", "Attendee instance change"} =>
    {:apple, "an instance answer's ATTENDEE change is not named"},
  {"implicitschedulechanges.xml", "Multi-instance change"} =>
    {:apple, "a changed DTEND across instances is not named"},

  # --- incidental: quota totals differ from the reference's bytes ---------
  {"quota.xml", "Quota after collection create, and PUT"} =>
    {:incidental, "the stored bytes are this server's canonical form, not the reference's"},
  # Two causes, neither a defect here. Twelve of the fourteen compare
  # byte counts that encode the reference's on-disk layout: it stores
  # each sharee's per-user data *inside* the object, wrapped in
  # `X-CALENDARSERVER-PERUSER`, and the fixtures are padded so that
  # wrapper lands on a round number. This server keeps personal parts
  # beside the object, so the same calendar occupies fewer bytes and
  # every figure in the file is off by the wrapper. The other two
  # follow from the file writing a second object with the *same*
  # `UID` into one calendar, which RFC 4791 section 5.3.2 forbids and
  # this server refuses; the reference accepts it because its
  # uniqueness index is scoped to the writing principal's home rather
  # than to the collection. What the file is really about — a shared
  # calendar's bytes belong to its owner, and every view reports the
  # owner's figure — holds, and `Dav.Cal.SharingTest` covers it.
  {"sharing-quota.xml", nil} =>
    {:incidental,
     "byte counts encode the reference's per-user on-disk wrapper, and the same-UID write it expects is refused per RFC 4791 section 5.3.2"},

  # --- incidental: another server's zone compiler ------------------------
  {"timezonestdservice.xml", "Query action=get"} =>
    {:incidental,
     "the fixtures are CalendarServer's own VTIMEZONE output for the 2016 database: its RRULE grouping of historical transitions and its TZNAME spellings, neither of which RFC 7808 specifies"},
  {"timezoneservice.xml", "Query method=get"} =>
    {:incidental,
     "the same CalendarServer VTIMEZONE fixtures; the GB and London ones spell TZNAME in a way IANA's data does not carry at all"}
}
