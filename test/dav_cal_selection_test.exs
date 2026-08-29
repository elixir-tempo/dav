defmodule Dav.Cal.SelectionTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.ICalendar
  alias Dav.Cal.Selection
  alias Dav.Xml

  doctest Dav.Cal.Selection

  @caldav "urn:ietf:params:xml:ns:caldav"

  @ics Enum.join(
         [
           "BEGIN:VCALENDAR",
           "PRODID:-//Example//EN",
           "BEGIN:VTIMEZONE",
           "TZID:Etc/UTC",
           "END:VTIMEZONE",
           "BEGIN:VEVENT",
           "UID:1",
           "SUMMARY:Standup",
           "DESCRIPTION:Everything anyone said",
           "BEGIN:VALARM",
           "ACTION:DISPLAY",
           "END:VALARM",
           "END:VEVENT",
           "END:VCALENDAR"
         ],
         "\r\n"
       ) <> "\r\n"

  defp selection(inner) do
    {:ok, element} =
      Xml.parse(
        ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="#{@caldav}">#{inner}</C:calendar-data>)
      )

    Selection.from_element(element)
  end

  test "no children means the object as stored" do
    assert Selection.apply(@ics, selection("")) == @ics
  end

  test "a client that asks for two properties gets two properties" do
    kept =
      Selection.apply(
        @ics,
        selection(
          ~s(<C:comp name="VCALENDAR"><C:comp name="VEVENT"><C:prop name="UID"/><C:prop name="SUMMARY"/></C:comp></C:comp>)
        )
      )

    assert kept =~ "UID:1"
    assert kept =~ "SUMMARY:Standup"
    # The point of asking for a subset is not receiving the rest.
    refute kept =~ "DESCRIPTION"

    # VCALENDAR itself named no properties, and RFC 4791 section 9.6.1
    # returns all of a component's properties when none are named — so
    # PRODID stays. Only VEVENT was narrowed.
    assert kept =~ "PRODID"
  end

  test "an unnamed component is left out entirely" do
    kept =
      Selection.apply(
        @ics,
        selection(~s(<C:comp name="VCALENDAR"><C:comp name="VEVENT"/></C:comp>))
      )

    assert kept =~ "BEGIN:VEVENT"
    refute kept =~ "VTIMEZONE"
  end

  test "a named component with no properties keeps all of them" do
    kept =
      Selection.apply(
        @ics,
        selection(~s(<C:comp name="VCALENDAR"><C:comp name="VEVENT"/></C:comp>))
      )

    assert kept =~ "DESCRIPTION:Everything anyone said"
    assert kept =~ "BEGIN:VALARM"
  end

  test "the result is still readable as iCalendar" do
    kept =
      Selection.apply(
        @ics,
        selection(
          ~s(<C:comp name="VCALENDAR"><C:comp name="VEVENT"><C:prop name="UID"/></C:comp></C:comp>)
        )
      )

    assert {:ok, calendar} = ICalendar.parse(kept)
    assert [%{name: "VEVENT"}] = calendar.components
    refute kept =~ "\r\n\r\n"
  end

  test "data that cannot be parsed is returned rather than dropped" do
    assert Selection.apply("not a calendar", selection(~s(<C:comp name="VCALENDAR"/>))) ==
             "not a calendar"
  end
end
