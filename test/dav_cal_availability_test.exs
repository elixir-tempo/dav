defmodule Dav.Cal.AvailabilityTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.Availability
  alias Dav.Cal.TimeRange

  doctest Dav.Cal.Availability

  # Monday to Friday, 09:00 to 17:00 in a fixed-offset zone, so the
  # arithmetic in the assertions is readable: UTC-5 all year, which
  # puts the window at 14:00Z to 22:00Z.
  defp weekdays(parts \\ []) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//test//EN
    BEGIN:VAVAILABILITY
    UID:availability-1
    DTSTAMP:20260101T000000Z
    DTSTART:20260101T000000Z
    #{Keyword.get(parts, :extra, "")}BEGIN:AVAILABLE
    UID:available-1
    DTSTAMP:20260101T000000Z
    DTSTART:20270104T140000Z
    DTEND:20270104T220000Z
    RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
    END:AVAILABLE
    END:VAVAILABILITY
    END:VCALENDAR
    """
    |> String.replace("\n", "\r\n")
  end

  defp gaps(stated, from, to) do
    {:ok, window} = TimeRange.bounds({from, to})

    stated
    |> Availability.unavailable(window, nil)
    |> Enum.map(fn {type, {began, ended}} -> {type, inspect(began), inspect(ended)} end)
  end

  describe "the unavailable stretches" do
    test "a day is unavailable either side of the available window" do
      assert [
               {"BUSY-UNAVAILABLE", opening, ~s(~o"2027Y1M4DT14H0M0SZ")},
               {"BUSY-UNAVAILABLE", ~s(~o"2027Y1M4DT22H0M0SZ"), closing}
             ] = gaps(weekdays(), "20270104T000000Z", "20270105T000000Z")

      assert opening == ~s(~o"2027Y1M4DT0H0M0SZ")
      assert closing == ~s(~o"2027Y1M5DT0H0M0SZ")
    end

    # The rule says weekdays. A Saturday has no available window at
    # all, so the whole day is time nobody should be asked about.
    test "a day the rule does not name is unavailable throughout" do
      assert [{"BUSY-UNAVAILABLE", from, to}] =
               gaps(weekdays(), "20270109T000000Z", "20270110T000000Z")

      assert from == ~s(~o"2027Y1M9DT0H0M0SZ")
      assert to == ~s(~o"2027Y1M10DT0H0M0SZ")
    end

    # A window that lies entirely inside the available hours leaves
    # nothing to report: the person is open for all of it.
    test "a window inside the available hours reports nothing" do
      assert gaps(weekdays(), "20270104T150000Z", "20270104T160000Z") == []
    end

    # `BUSYTYPE` names what the time outside the windows is called.
    # RFC 7953 section 3.1 defaults it to `BUSY-UNAVAILABLE`, and a
    # component saying otherwise means it.
    test "BUSYTYPE names the kind of unavailable time" do
      stated = weekdays(extra: "BUSYTYPE:BUSY-TENTATIVE\n")

      assert [{"BUSY-TENTATIVE", _from, _to} | _rest] =
               gaps(stated, "20270104T000000Z", "20270105T000000Z")
    end

    # A `VAVAILABILITY` speaks for the stretch it bounds and says
    # nothing about time outside it. Reporting the rest as unavailable
    # would answer a question the rule never addressed.
    test "time outside the component's own bounds is not reported" do
      stated =
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VAVAILABILITY
        UID:availability-1
        DTSTAMP:20260101T000000Z
        DTSTART:20270104T000000Z
        DTEND:20270104T120000Z
        END:VAVAILABILITY
        END:VCALENDAR
        """
        |> String.replace("\n", "\r\n")

      assert [{"BUSY-UNAVAILABLE", from, to}] =
               gaps(stated, "20270104T000000Z", "20270105T000000Z")

      assert from == ~s(~o"2027Y1M4DT0H0M0SZ")
      assert to == ~s(~o"2027Y1M4DT12H0M0SZ")
    end

    test "nothing stated means nothing is unavailable" do
      assert gaps(nil, "20270104T000000Z", "20270105T000000Z") == []
    end

    # An unbounded question has no complement to take: every moment
    # from the beginning of time is not an answer anybody wants.
    test "an unbounded window reports nothing" do
      {:ok, window} = TimeRange.bounds({"20270104T000000Z", nil})

      assert Availability.unavailable(weekdays(), window, nil) == []
    end

    test "a value that is not calendar data reports nothing" do
      assert gaps("This is not a calendar!", "20270104T000000Z", "20270105T000000Z") == []
    end
  end

  describe "what may be stored" do
    test "a calendar is accepted" do
      instruction = {:set, Availability.property(), weekdays()}

      assert Availability.patchable(nil, instruction, %{}) == :ok
    end

    # A property nobody validates is one the free-busy code has to
    # distrust on every read.
    test "anything else is refused, naming the property" do
      instruction = {:set, Availability.property(), "This is not a calendar!"}

      assert Availability.patchable(nil, instruction, %{}) == {:error, Availability.property()}
    end

    test "another property is not this hook's business" do
      instruction = {:set, {"DAV:", "displayname"}, "Work"}

      assert Availability.patchable(nil, instruction, %{}) == :ok
    end
  end
end
