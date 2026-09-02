defmodule Dav.Cal.TimeRangeTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange

  doctest Dav.Cal.TimeRange

  defp event(lines) do
    data =
      (["BEGIN:VCALENDAR", "BEGIN:VEVENT"] ++ lines ++ ["END:VEVENT", "END:VCALENDAR"])
      |> Enum.join("\r\n")
      |> Kernel.<>("\r\n")

    {:ok, calendar} = ICalendar.parse(data)
    hd(calendar.components)
  end

  defp overlaps?(lines, range), do: TimeRange.overlaps?(event(lines), range)

  # Windows reach the API as instants, so the tests read theirs the
  # same way a request does.
  defp window(range) do
    {:ok, window} = TimeRange.bounds(range)
    window
  end

  @day {"20260615T000000Z", "20260616T000000Z"}

  describe "with DTEND" do
    test "an event inside the range overlaps" do
      assert overlaps?(["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"], window(@day))
    end

    test "an event wholly before it does not" do
      refute overlaps?(["DTSTART:20260614T090000Z", "DTEND:20260614T100000Z"], window(@day))
    end

    test "an event ending exactly at the range start does not overlap" do
      # `start < DTEND` is strict: an event that finishes as the window
      # opens is not in it.
      refute overlaps?(["DTSTART:20260614T230000Z", "DTEND:20260615T000000Z"], window(@day))
    end

    test "an event starting exactly at the range end does not overlap" do
      # `end > DTSTART`, and end is non-inclusive.
      refute overlaps?(["DTSTART:20260616T000000Z", "DTEND:20260616T010000Z"], window(@day))
    end

    test "an event spanning the whole range overlaps" do
      assert overlaps?(["DTSTART:20260601T000000Z", "DTEND:20260701T000000Z"], window(@day))
    end
  end

  describe "with DURATION" do
    test "a positive duration behaves like DTEND" do
      assert overlaps?(["DTSTART:20260615T090000Z", "DURATION:PT1H"], window(@day))
      refute overlaps?(["DTSTART:20260614T220000Z", "DURATION:PT1H"], window(@day))
    end

    test "a zero duration at the range start does overlap" do
      # The row that catches people: for a zero-length event the
      # comparison is `start <= DTSTART`, not `<`.
      assert overlaps?(["DTSTART:20260615T000000Z", "DURATION:PT0S"], window(@day))
    end
  end

  describe "with neither" do
    test "a date-time DTSTART is an instant" do
      assert overlaps?(["DTSTART:20260615T090000Z"], window(@day))
      refute overlaps?(["DTSTART:20260616T090000Z"], window(@day))
    end

    test "an instant exactly at the range start overlaps" do
      assert overlaps?(["DTSTART:20260615T000000Z"], window(@day))
    end

    test "a date-valued DTSTART lasts a day" do
      assert overlaps?(["DTSTART;VALUE=DATE:20260615"], window(@day))
    end

    test "and the day before does not reach into the range" do
      refute overlaps?(["DTSTART;VALUE=DATE:20260614"], window(@day))
    end
  end

  describe "open ranges" do
    test "an open end means everything after the start" do
      assert overlaps?(["DTSTART:20270101T000000Z"], window({"20260615T000000Z", nil}))
      refute overlaps?(["DTSTART:20260101T000000Z"], window({"20260615T000000Z", nil}))
    end

    test "an open start means everything before the end" do
      assert overlaps?(["DTSTART:20260101T000000Z"], window({nil, "20260615T000000Z"}))
      refute overlaps?(["DTSTART:20270101T000000Z"], window({nil, "20260615T000000Z"}))
    end
  end

  describe "what cannot be placed" do
    test "a component with no DTSTART never overlaps" do
      refute overlaps?(["SUMMARY:Undated"], window(@day))
    end

    test "an unreadable DTSTART is not a crash" do
      refute overlaps?(["DTSTART:not-a-date"], window(@day))
    end
  end

  describe "recurrence" do
    test "the first instance is found" do
      assert overlaps?(
               [
                 "DTSTART:20260601T090000Z",
                 "DTEND:20260601T100000Z",
                 "RRULE:FREQ=WEEKLY;COUNT=5"
               ],
               window({"20260601T000000Z", "20260602T000000Z"})
             )
    end

    test "a later instance inside the range counts, as the specification requires" do
      # RFC 4791 section 9.9: "Time range tests MUST consider every
      # recurrence instance ... if any one instance matches, then the
      # test returns true." The event starts on 1 June; the window is
      # the 15th, which only the third occurrence reaches.
      assert overlaps?(
               [
                 "DTSTART:20260601T090000Z",
                 "DTEND:20260601T100000Z",
                 "RRULE:FREQ=WEEKLY;COUNT=5"
               ],
               window({"20260615T000000Z", "20260616T000000Z"})
             )
    end
  end

  describe "time zones" do
    test "a TZID is applied, not ignored" do
      # 09:00 in Los Angeles is 16:00 UTC. Reading the value as UTC
      # puts the event seven hours early, which is enough to move it
      # out of the window a client asked about.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;TZID=America/Los_Angeles:20260615T090000\r\n" <>
          "DTEND;TZID=America/Los_Angeles:20260615T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      [event] = calendar.components

      # 16:00-17:00 UTC: inside an afternoon window...
      assert TimeRange.overlaps?(event, window({"20260615T150000Z", "20260615T180000Z"}))
      # ...and outside a morning one, which a UTC reading would match.
      refute TimeRange.overlaps?(event, window({"20260615T080000Z", "20260615T100000Z"}))
    end

    test "an unresolvable zone leaves the time as written" do
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;TZID=Made/Up:20260615T090000\r\n" <>
          "DTEND;TZID=Made/Up:20260615T100000\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      [event] = calendar.components

      assert TimeRange.overlaps?(event, window({"20260615T080000Z", "20260615T100000Z"}))
    end
  end

  describe "floating times" do
    test "a floating time is read in the zone the caller supplies" do
      # No TZID and no Z: the same wall-clock reading everywhere, so
      # the caller says which zone to resolve it in.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20270101T010000\r\nDTEND:20270101T020000\r\n" <>
          "END:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      [event] = calendar.components

      # 01:00 in New York is 06:00 UTC.
      assert TimeRange.overlaps?(
               event,
               window({"20270101T055000Z", "20270101T070000Z"}),
               "America/New_York"
             )

      refute TimeRange.overlaps?(
               event,
               window({"20270101T003000Z", "20270101T004000Z"}),
               "America/New_York"
             )
    end

    test "an all-day value is midnight in that zone, not midnight UTC" do
      # The case that made a whole-day event five hours too early.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20270102\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      [event] = calendar.components

      # The day begins at 05:00Z, so a window ending then excludes it.
      refute TimeRange.overlaps?(
               event,
               window({"20270101T050000Z", "20270102T050000Z"}),
               "America/New_York"
             )

      assert TimeRange.overlaps?(
               event,
               window({"20270102T050000Z", "20270103T050000Z"}),
               "America/New_York"
             )
    end
  end

  describe "VTODO" do
    defp todo(properties) do
      ics =
        Enum.join(
          ["BEGIN:VCALENDAR", "BEGIN:VTODO", "UID:1"] ++
            properties ++ ["END:VTODO", "END:VCALENDAR"],
          "\r\n"
        ) <>
          "\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      hd(calendar.components)
    end

    test "a task with no times at all is always in range" do
      # The last row of RFC 4791 section 9.9's table is simply TRUE:
      # there is no evidence the task falls outside any window.
      assert TimeRange.overlaps?(
               todo(["SUMMARY:someday"]),
               window({"20260101T000000Z", "20260102T000000Z"})
             )
    end

    test "a task with only a DUE is placed by it" do
      task = todo(["DUE:20260615T170000Z"])

      assert TimeRange.overlaps?(task, window({"20260615T000000Z", "20260616T000000Z"}))
      refute TimeRange.overlaps?(task, window({"20260101T000000Z", "20260102T000000Z"}))
    end

    test "a task with only a COMPLETED is placed by it" do
      task = todo(["COMPLETED:20260615T170000Z"])

      assert TimeRange.overlaps?(task, window({"20260615T000000Z", "20260616T000000Z"}))
      refute TimeRange.overlaps?(task, window({"20260101T000000Z", "20260102T000000Z"}))
    end

    test "a task with only a CREATED is in range from then on" do
      task = todo(["CREATED:20260615T170000Z"])

      assert TimeRange.overlaps?(task, window({"20260616T000000Z", "20260617T000000Z"}))
      refute TimeRange.overlaps?(task, window({"20260101T000000Z", "20260102T000000Z"}))
    end

    test "DTSTART with DURATION uses the whole span" do
      task = todo(["DTSTART:20260615T090000Z", "DURATION:PT2H"])

      assert TimeRange.overlaps?(task, window({"20260615T100000Z", "20260615T103000Z"}))
      refute TimeRange.overlaps?(task, window({"20260615T120000Z", "20260615T130000Z"}))
    end
  end
end
