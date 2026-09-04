defmodule Dav.Cal.TravelTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.FreeBusy
  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange
  alias Dav.Cal.Travel

  doctest Dav.Cal.Travel

  # An hour at 23:00Z, the shape every travel-time fixture uses.
  defp event(parts) do
    (["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:1"] ++
       ["DTSTART:20270104T230000Z", "DURATION:PT1H"] ++ parts ++ ["END:VEVENT", "END:VCALENDAR"])
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp busy(parts, from \\ "20270104T000000Z", to \\ "20270108T000000Z") do
    {:ok, calendar} = ICalendar.parse(event(parts))
    {:ok, window} = TimeRange.bounds({from, to})

    calendar
    |> FreeBusy.periods_of(window)
    |> Enum.map(fn {type, {began, ended}} -> {type, inspect(began), inspect(ended)} end)
  end

  describe "reading the journey" do
    test "a duration is kept as written" do
      {:ok, %{components: [event]}} = ICalendar.parse(event(["X-APPLE-TRAVEL-DURATION:PT30M"]))

      assert Travel.of(event) == {"PT30M", nil}
    end

    test "both ends are read" do
      {:ok, %{components: [event]}} =
        ICalendar.parse(
          event(["X-APPLE-TRAVEL-DURATION:PT30M", "X-APPLE-TRAVEL-RETURN-DURATION:PT25M"])
        )

      assert Travel.of(event) == {"PT30M", "PT25M"}
    end

    # The locations are for a client drawing a map. Reading them as
    # times would move the event to wherever the person set off from.
    test "the location properties say nothing about time" do
      {:ok, %{components: [event]}} =
        ICalendar.parse(event(["X-APPLE-TRAVEL-START:geo:40.450731,-79.909591"]))

      assert Travel.of(event) == {nil, nil}
    end

    test "a duration that will not parse is not a duration" do
      {:ok, %{components: [event]}} = ICalendar.parse(event(["X-APPLE-TRAVEL-DURATION:soon"]))

      assert Travel.of(event) == {nil, nil}
    end
  end

  describe "the busy time it produces" do
    test "an event with no travel is busy for exactly its own hour" do
      assert busy([]) == [{"BUSY", ~s(~o"2027Y1M4DT23H0M0SZ"), ~s(~o"2027Y1M5DT0H0M0SZ")}]
    end

    test "getting there starts the busy period earlier" do
      assert busy(["X-APPLE-TRAVEL-DURATION:PT1H"]) ==
               [{"BUSY", ~s(~o"2027Y1M4DT22H0M0SZ"), ~s(~o"2027Y1M5DT0H0M0SZ")}]
    end

    test "getting back ends it later" do
      assert busy(["X-APPLE-TRAVEL-RETURN-DURATION:PT30M"]) ==
               [{"BUSY", ~s(~o"2027Y1M4DT23H0M0SZ"), ~s(~o"2027Y1M5DT0H30M0SZ")}]
    end

    test "both ends move independently" do
      assert busy(["X-APPLE-TRAVEL-DURATION:PT30M", "X-APPLE-TRAVEL-RETURN-DURATION:PT25M"]) ==
               [{"BUSY", ~s(~o"2027Y1M4DT22H30M0SZ"), ~s(~o"2027Y1M5DT0H25M0SZ")}]
    end

    # A client that wrote its journey as a negative duration still
    # means a journey. Reading the sign would make the traveller
    # available during it.
    test "a duration written negative still occupies time before the event" do
      assert busy(["X-APPLE-TRAVEL-DURATION:-PT1H"]) ==
               [{"BUSY", ~s(~o"2027Y1M4DT22H0M0SZ"), ~s(~o"2027Y1M5DT0H0M0SZ")}]
    end

    # The point of widening the search: the meeting is outside the
    # window, but the journey to it is not, and a slot offered inside
    # that journey is a slot nobody can take.
    test "an event outside the window is busy inside it while travelling" do
      assert busy(["X-APPLE-TRAVEL-DURATION:PT2H"], "20270104T213000Z", "20270104T220000Z") ==
               [{"BUSY", ~s(~o"2027Y1M4DT21H30M0SZ"), ~s(~o"2027Y1M4DT22H0M0SZ")}]
    end

    # The window bounds what is reported, travel included: a journey
    # running past the edge is busy up to the edge and no further.
    test "the journey is trimmed to the window like anything else" do
      assert busy(["X-APPLE-TRAVEL-RETURN-DURATION:PT2H"], "20270104T000000Z", "20270105T003000Z") ==
               [{"BUSY", ~s(~o"2027Y1M4DT23H0M0SZ"), ~s(~o"2027Y1M5DT0H30M0SZ")}]
    end

    # Travel to a meeting nobody is attending is not time spent.
    test "a transparent event stays free, journey and all" do
      assert busy(["TRANSP:TRANSPARENT", "X-APPLE-TRAVEL-DURATION:PT1H"]) == []
    end
  end
end
