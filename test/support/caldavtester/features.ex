defmodule Dav.CalDAVTester.Features do
  @moduledoc """
  What this server declares to the conformance suite.

  CalDAVTester gates 850 of its own blocks on `<require-feature>` and
  `<exclude-feature>`, read against a `serverinfo.xml` that describes
  *the server under test*. Apple's own file declares 84 features
  because Apple's server implements 84 features; running this server
  against that list asks it thousands of questions it never claimed to
  answer.

  So the list here is this server's, and it is deliberately short. It
  grows only when the capability is actually implemented — a feature
  declared but not built turns a conformance figure into a claim
  rather than a measurement, which is the failure this whole harness
  exists to avoid.

  ### Reading the numbers

  Two figures are worth quoting and they are not interchangeable:

  * **applicable** — tests the suite would put to a server declaring
    these features. This is the conformance denominator.

  * **whole suite** — every CalDAV test regardless of declaration,
    which measures distance from a full groupware server.

  """

  # Implemented and exercised. Each entry is a claim that can be
  # checked against the code:
  #
  #   caldav        — RFC 4791 calendar-access: MKCALENDAR, the
  #                   calendar collection type, calendar-query,
  #                   calendar-multiget, free-busy-query.
  #   COPY Method   — RFC 4918 COPY, dispatched and store-backed.
  #   MOVE Method   — RFC 4918 MOVE, likewise.
  #   regular-collection — ordinary collections may be created inside
  #                   a calendar home, which MKCOL supports.
  #   current-user-principal, REPORT principal-* , expand-property
  #                 — RFC 3744 discovery and RFC 5397, in
  #                   `Dav.Web.Principal` and `Dav.Web.Acl`. The `ACL`
  #                   *method* is deliberately not declared: the
  #                   properties are computed from ownership and
  #                   cannot yet be written.
  @declared ~w(caldav) ++
              [
                "COPY Method",
                "MOVE Method",
                "regular-collection",
                # RFC 3744's discovery reports and RFC 5397's
                # `DAV:current-user-principal`, in `Dav.Web.Principal`.
                "current-user-principal",
                "acl-principal-prop-set",
                "REPORT principal-match",
                "REPORT principal-property-search",
                "REPORT principal-search-property-set",
                "expand-property",
                # RFC 6578 collection synchronisation, in
                # `Dav.Web.Sync`: calendars and the Inbox answer the
                # `DAV:sync-collection` report and carry a
                # `DAV:sync-token`, and so does the calendar home —
                # at `DAV:sync-level` 1 the home reports which child
                # collections changed, at `infinity` also what changed
                # inside them.
                "sync-report",
                "sync-report-home",
                # RFC 6638 auto-scheduling for rooms and resources, in
                # `Dav.Cal.Scheduling`: an unattended recipient's copy
                # answers on arrival.
                "auto-accept",
                # RFC 7240 preferences, in `Dav.Web.Plug`: minimal
                # answers, rootless listings, and writes answered with
                # the stored representation.
                # The extended query grammar: `test="anyof"` on
                # `comp-filter` and `prop-filter`, in `Dav.Cal.Filter`.
                "query-extended",
                "prefer",
                "prefer-minimal",
                "prefer-noroot",
                "prefer-representation",
                # RFC 6638 implicit scheduling, in `Dav.Cal.Scheduling`:
                # storing an event with attendees delivers the
                # invitations, and an attendee's reply reaches the
                # organiser.
                "implicit-scheduling",
                # Apple's sharing extension, in `Dav.Cal.Sharing`:
                # invitations, notifications, and the shared-calendar
                # properties. Not an RFC, and the most widely deployed
                # CalDAV extension there is.
                "shared-calendars",
                # RFC 7809 posture: a `TZID` naming a zone the server
                # knows is accepted without an inline `VTIMEZONE`
                # (`Dav.Cal.Object`'s `timezones_present/1` resolves
                # known zones), so the strict-inclusion error test
                # excludes itself.
                "timezones-by-reference"
              ]

  @doc """
  The features this server declares.

  ### Returns

  * A `MapSet` of feature names.

  ### Examples

      iex> Dav.CalDAVTester.Features.declared() |> MapSet.member?("caldav")
      true

      iex> Dav.CalDAVTester.Features.declared() |> MapSet.member?("dropbox")
      false

  """
  @spec declared() :: MapSet.t()
  def declared, do: MapSet.new(@declared)
end
