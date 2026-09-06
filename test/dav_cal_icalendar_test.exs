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

  describe "real-world input" do
    test "a UTF-8 byte order mark does not make the object malformed" do
      # Left in place the BOM becomes part of the first line, so
      # `BEGIN:VCALENDAR` reads as something else and the whole object
      # parses as empty.
      ics =
        <<0xEF, 0xBB, 0xBF>> <>
          "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      assert {:ok, calendar} = ICalendar.parse(ics)
      assert [%{name: "VEVENT"}] = calendar.components
    end

    test "bare LF line endings are read, not only CRLF" do
      ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:1\nEND:VEVENT\nEND:VCALENDAR\n"

      assert {:ok, calendar} = ICalendar.parse(ics)
      assert [%{name: "VEVENT"}] = calendar.components
    end
  end

  describe "writing" do
    test "a recurrence rule is not escaped" do
      # `RRULE:FREQ=WEEKLY;BYDAY=MO,TU` uses `;` and `,` as structure.
      # Escaping them turns a rule into one unparseable string, which
      # is what happened to every VTIMEZONE this rewrote.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) =~ "RRULE:FREQ=WEEKLY;BYDAY=MO,TU"
    end

    test "a TEXT value is escaped" do
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nSUMMARY:one\\, two\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) =~ "SUMMARY:one\\, two"
    end

    test "an extension property keeps the escapes it arrived with" do
      # Found by Apple's harness against the real server, and invisible
      # to the corpus, whose comparison parses both sides. Parsing
      # unescaped every value while writing re-escaped only the known
      # `TEXT` ones, so anything else lost `\,` for good: a client
      # storing `a\,b` read back `a,b`, a different value.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nX-TEST:one\\, two\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) =~ "X-TEST:one\\, two"
    end

    test "and gains none it did not" do
      # The other half, and why the fix is not "treat X- as TEXT": the
      # suite sends both spellings and wants both back untouched.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nX-TEST:geo:1.1,2.2\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) =~ "X-TEST:geo:1.1,2.2"
    end

    test "a URI a client wrongly escaped is repaired" do
      # `put.xml`'s "relaxed parsing": a known property whose type is
      # not `TEXT` is unescaped on the way in and not escaped again,
      # and that asymmetry is deliberate. Stopping it to fix the
      # extension case cost this test.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nURL:http://x.example\\,y\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) =~ "URL:http://x.example,y"
    end

    test "a property is written as the client spelled it" do
      # RFC 5545 section 3.1 makes names case-insensitive, so `:name`
      # is upper-cased and every comparison in the library is written
      # against one spelling. Handing that back is a different matter:
      # a client that stored `X-Test` and read `X-TEST` is given
      # something it did not write.
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nX-Test:a\r\nsummary:b\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      written = ICalendar.write(calendar)

      assert written =~ "X-Test:a"
      assert written =~ "summary:b"
    end

    test "and is still matched under one" do
      ics =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nX-Test:a\r\nsummary:b\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

      {:ok, calendar} = ICalendar.parse(ics)
      [event] = calendar.components

      # The half that makes the other half safe: nothing downstream
      # has to learn about spelling to keep working.
      assert "X-TEST" in Enum.map(event.properties, & &1.name)
      assert "SUMMARY" in Enum.map(event.properties, & &1.name)
    end

    test "and a property the server built is written as named" do
      built = %{
        name: "VERSION",
        properties: [%{name: "X-MADE-HERE", parameters: %{}, value: "yes"}],
        components: []
      }

      assert ICalendar.write(%{built | name: "VCALENDAR"}) =~ "X-MADE-HERE:yes"
    end

    test "a whole calendar survives a round trip" do
      ics =
        Enum.join(
          [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "BEGIN:VTIMEZONE",
            "TZID:US/Eastern",
            "BEGIN:DAYLIGHT",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
            "TZNAME:EDT",
            "END:DAYLIGHT",
            "END:VTIMEZONE",
            "BEGIN:VEVENT",
            "UID:1",
            "DTSTART;TZID=US/Eastern:20260615T090000",
            "END:VEVENT",
            "END:VCALENDAR"
          ],
          "\r\n"
        ) <> "\r\n"

      {:ok, calendar} = ICalendar.parse(ics)

      assert ICalendar.write(calendar) == ics
    end
  end
end
