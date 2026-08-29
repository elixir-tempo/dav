defmodule Dav.Cal.ICalendarTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.ICalendar

  doctest Dav.Cal.ICalendar

  defp ics(lines), do: Enum.join(lines, "\r\n") <> "\r\n"

  describe "structure" do
    test "components nest" do
      {:ok, calendar} =
        ics([
          "BEGIN:VCALENDAR",
          "BEGIN:VEVENT",
          "BEGIN:VALARM",
          "ACTION:DISPLAY",
          "END:VALARM",
          "END:VEVENT",
          "END:VCALENDAR"
        ])
        |> ICalendar.parse()

      [event] = calendar.components
      [alarm] = event.components
      assert alarm.name == "VALARM"
    end

    test "an unterminated component is malformed" do
      assert {:error, :malformed} = ICalendar.parse(ics(["BEGIN:VCALENDAR", "BEGIN:VEVENT"]))
    end
  end

  describe "content lines" do
    test "parameters are read, and their names normalised" do
      {:ok, calendar} =
        ics([
          "BEGIN:VCALENDAR",
          "ATTENDEE;partstat=ACCEPTED;CN=Kim:mailto:kim@example.test",
          "END:VCALENDAR"
        ])
        |> ICalendar.parse()

      [attendee] = calendar.properties
      assert attendee.name == "ATTENDEE"
      assert attendee.parameters["PARTSTAT"] == "ACCEPTED"
      assert attendee.parameters["CN"] == "Kim"
    end

    test "the value keeps colons that belong to it" do
      {:ok, calendar} =
        ics(["BEGIN:VCALENDAR", "ATTENDEE:mailto:kim@example.test", "END:VCALENDAR"])
        |> ICalendar.parse()

      assert hd(calendar.properties).value == "mailto:kim@example.test"
    end

    test "a colon inside a quoted parameter does not end the parameters" do
      {:ok, calendar} =
        ics([
          "BEGIN:VCALENDAR",
          ~s(ATTENDEE;MEMBER="mailto:team@example.test":mailto:kim@example.test),
          "END:VCALENDAR"
        ])
        |> ICalendar.parse()

      [attendee] = calendar.properties
      assert attendee.parameters["MEMBER"] == "mailto:team@example.test"
      assert attendee.value == "mailto:kim@example.test"
    end

    test "folded lines are rejoined without the break" do
      # RFC 5545 section 3.1. Real clients fold aggressively, so a
      # parser that misses this mangles most long summaries.
      data =
        "BEGIN:VCALENDAR\r\nSUMMARY:A very long summ\r\n ary that was folded\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(data)

      assert hd(calendar.properties).value == "A very long summary that was folded"
    end

    test "escapes in a value are undone" do
      {:ok, calendar} =
        ics(["BEGIN:VCALENDAR", "DESCRIPTION:one\\, two\\nthree", "END:VCALENDAR"])
        |> ICalendar.parse()

      assert hd(calendar.properties).value == "one, two\nthree"
    end

    test "a property this library has never heard of is kept, not dropped" do
      # The whole reason for reading structure rather than meaning: a
      # filter may name any property at all.
      {:ok, calendar} =
        ics(["BEGIN:VCALENDAR", "X-APPLE-TRAVEL-DURATION;VALUE=DURATION:PT30M", "END:VCALENDAR"])
        |> ICalendar.parse()

      [property] = calendar.properties
      assert property.name == "X-APPLE-TRAVEL-DURATION"
      assert property.parameters["VALUE"] == "DURATION"
      assert property.value == "PT30M"
    end
  end
end
