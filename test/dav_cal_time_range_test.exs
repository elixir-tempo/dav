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

  @day {"20260615T000000Z", "20260616T000000Z"}

  describe "with DTEND" do
    test "an event inside the range overlaps" do
      assert overlaps?(["DTSTART:20260615T090000Z", "DTEND:20260615T100000Z"], @day)
    end

    test "an event wholly before it does not" do
      refute overlaps?(["DTSTART:20260614T090000Z", "DTEND:20260614T100000Z"], @day)
    end

    test "an event ending exactly at the range start does not overlap" do
      # `start < DTEND` is strict: an event that finishes as the window
      # opens is not in it.
      refute overlaps?(["DTSTART:20260614T230000Z", "DTEND:20260615T000000Z"], @day)
    end

    test "an event starting exactly at the range end does not overlap" do
      # `end > DTSTART`, and end is non-inclusive.
      refute overlaps?(["DTSTART:20260616T000000Z", "DTEND:20260616T010000Z"], @day)
    end

    test "an event spanning the whole range overlaps" do
      assert overlaps?(["DTSTART:20260601T000000Z", "DTEND:20260701T000000Z"], @day)
    end
  end

  describe "with DURATION" do
    test "a positive duration behaves like DTEND" do
      assert overlaps?(["DTSTART:20260615T090000Z", "DURATION:PT1H"], @day)
      refute overlaps?(["DTSTART:20260614T220000Z", "DURATION:PT1H"], @day)
    end

    test "a zero duration at the range start does overlap" do
      # The row that catches people: for a zero-length event the
      # comparison is `start <= DTSTART`, not `<`.
      assert overlaps?(["DTSTART:20260615T000000Z", "DURATION:PT0S"], @day)
    end
  end

  describe "with neither" do
    test "a date-time DTSTART is an instant" do
      assert overlaps?(["DTSTART:20260615T090000Z"], @day)
      refute overlaps?(["DTSTART:20260616T090000Z"], @day)
    end

    test "an instant exactly at the range start overlaps" do
      assert overlaps?(["DTSTART:20260615T000000Z"], @day)
    end

    test "a date-valued DTSTART lasts a day" do
      assert overlaps?(["DTSTART;VALUE=DATE:20260615"], @day)
    end

    test "and the day before does not reach into the range" do
      refute overlaps?(["DTSTART;VALUE=DATE:20260614"], @day)
    end
  end

  describe "open ranges" do
    test "an open end means everything after the start" do
      assert overlaps?(["DTSTART:20270101T000000Z"], {"20260615T000000Z", nil})
      refute overlaps?(["DTSTART:20260101T000000Z"], {"20260615T000000Z", nil})
    end

    test "an open start means everything before the end" do
      assert overlaps?(["DTSTART:20260101T000000Z"], {nil, "20260615T000000Z"})
      refute overlaps?(["DTSTART:20270101T000000Z"], {nil, "20260615T000000Z"})
    end
  end

  describe "what cannot be placed" do
    test "a component with no DTSTART never overlaps" do
      refute overlaps?(["SUMMARY:Undated"], @day)
    end

    test "an unreadable DTSTART is not a crash" do
      refute overlaps?(["DTSTART:not-a-date"], @day)
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
               {"20260601T000000Z", "20260602T000000Z"}
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
               {"20260615T000000Z", "20260616T000000Z"}
             )
    end
  end
end
