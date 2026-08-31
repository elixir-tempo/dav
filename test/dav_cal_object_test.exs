defmodule Dav.Cal.ObjectTest do
  use ExUnit.Case, async: true

  alias Dav.Cal
  alias Dav.Cal.Object
  alias Dav.Web.Resource

  doctest Dav.Cal.Object

  @caldav "urn:ietf:params:xml:ns:caldav"

  defp calendar(lines) do
    Enum.join(["BEGIN:VCALENDAR"] ++ lines ++ ["END:VCALENDAR"], "\r\n") <> "\r\n"
  end

  defp event(properties) do
    calendar(["BEGIN:VEVENT", "UID:1"] ++ properties ++ ["END:VEVENT"])
  end

  defp validate(body, options \\ %{}), do: Object.validate(body, nil, [], options)

  describe "media type" do
    test "a non-calendar media type fails supported-calendar-data" do
      # A client sending vCard to a calendar needs to hear that its
      # media type is wrong, not that its calendar data is invalid.
      assert validate(event([]), %{content_type: "text/vcard"}) ==
               {:error, {@caldav, "supported-calendar-data"}}
    end

    test "text/calendar with parameters is accepted" do
      assert validate(event([]), %{content_type: "text/calendar; charset=utf-8"}) == :ok
    end
  end

  describe "structure" do
    test "two component types in one resource is refused" do
      body =
        calendar(["BEGIN:VEVENT", "UID:1", "END:VEVENT", "BEGIN:VTODO", "UID:1", "END:VTODO"])

      assert validate(body) == {:error, {@caldav, "valid-calendar-object-resource"}}
    end

    test "a VTIMEZONE alongside a component is allowed" do
      body =
        calendar([
          "BEGIN:VTIMEZONE",
          "TZID:Etc/UTC",
          "END:VTIMEZONE",
          "BEGIN:VEVENT",
          "UID:1",
          "END:VEVENT"
        ])

      assert validate(body) == :ok
    end

    test "differing UIDs belong in separate resources" do
      body =
        calendar(["BEGIN:VEVENT", "UID:1", "END:VEVENT", "BEGIN:VEVENT", "UID:2", "END:VEVENT"])

      assert validate(body) == {:error, {@caldav, "valid-calendar-object-resource"}}
    end

    test "a recurrence set shares one UID and is allowed" do
      body =
        calendar([
          "BEGIN:VEVENT",
          "UID:1",
          "END:VEVENT",
          "BEGIN:VEVENT",
          "UID:1",
          "RECURRENCE-ID:20260615T090000Z",
          "END:VEVENT"
        ])

      assert validate(body) == :ok
    end

    test "a METHOD makes it a scheduling message, not a stored object" do
      body = calendar(["METHOD:REQUEST", "BEGIN:VEVENT", "UID:1", "END:VEVENT"])

      assert validate(body) == {:error, {@caldav, "valid-calendar-object-resource"}}
    end
  end

  describe "values" do
    test "a control character is refused" do
      assert validate(event(["SUMMARY:bad\ahere"])) ==
               {:error, {@caldav, "valid-calendar-data"}}
    end

    test "an unparseable RRULE is refused" do
      assert validate(event(["RRULE:FREQ=NONSENSE"])) ==
               {:error, {@caldav, "valid-calendar-data"}}
    end

    test "a valid RRULE this server cannot expand is still accepted" do
      # Refusing what this server merely cannot model would reject
      # correct client data.
      assert validate(event(["RRULE:FREQ=MONTHLY;INTERVAL=2;BYSETPOS=-1;BYDAY=MO,TU,WE"])) == :ok
    end

    test "a malformed escape sequence is refused" do
      assert validate(event(["SUMMARY:one\\qtwo"])) == {:error, {@caldav, "valid-calendar-data"}}
    end

    test "escaped text is accepted, and the escapes are not mistaken for controls" do
      # The reader turns these into real characters, so checking the
      # decoded value would see a newline and refuse valid data.
      assert validate(event(["SUMMARY:a\\, b\\; c\\nd\\\\e"])) == :ok
    end
  end

  describe "time zones" do
    test "a resolvable IANA zone needs no VTIMEZONE" do
      # RFC 7809: a client may name a well-known zone by reference.
      assert validate(event(["DTSTART;TZID=America/Los_Angeles:20260615T090000"])) == :ok
    end

    test "an unresolvable zone must carry its definition" do
      # RFC 7809: with timezones by reference, an identifier the
      # server cannot resolve fails `CALDAV:valid-timezone`.
      assert validate(event(["DTSTART;TZID=Made/Up:20260615T090000"])) ==
               {:error, {@caldav, "valid-timezone"}}
    end

    test "an unresolvable zone with its VTIMEZONE is accepted" do
      body =
        calendar([
          "BEGIN:VTIMEZONE",
          "TZID:Made/Up",
          "END:VTIMEZONE",
          "BEGIN:VEVENT",
          "UID:1",
          "DTSTART;TZID=Made/Up:20260615T090000",
          "END:VEVENT"
        ])

      assert validate(body) == :ok
    end
  end

  describe "encoding" do
    test "non-ASCII UTF-8 is accepted" do
      assert validate(event(["SUMMARY:Réunion avec Zoë — 日本語"])) == :ok
    end

    test "bytes that are not valid UTF-8 are refused" do
      # iCalendar is UTF-8 (RFC 5545 section 6), and a byte-level
      # control check over invalid UTF-8 does not mean what it looks
      # like it means.
      body = event(["SUMMARY:x"]) <> <<0xFF, 0xFE>>

      assert validate(body) == {:error, {@caldav, "valid-calendar-data"}}
    end
  end

  test "too many attendees on one instance is refused" do
    attendees = for n <- 1..200, do: "ATTENDEE:mailto:person#{n}@example.com"

    assert validate(event(attendees)) == {:error, {@caldav, "max-attendees-per-instance"}}
  end

  test "it applies only inside a calendar collection" do
    refute Object.applies?(%Resource{collection?: true})
    assert Object.applies?(%Resource{collection?: true, types: [Cal.calendar()]})
  end
end
