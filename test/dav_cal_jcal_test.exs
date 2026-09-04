defmodule Dav.Cal.JCalTest do
  use ExUnit.Case, async: true

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Cal.JCal
  alias Dav.Web.Resource

  doctest Dav.Cal.JCal

  defp calendar(lines) do
    (["BEGIN:VCALENDAR", "VERSION:2.0"] ++ lines ++ ["END:VCALENDAR"])
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp encoded(lines) do
    {:ok, component} = ICalendar.parse(calendar(lines))

    component |> JCal.encode() |> :json.decode()
  end

  defp property(lines, name) do
    [_calendar, properties, components] = encoded(lines)

    Enum.find(properties ++ Enum.flat_map(components, fn [_n, p, _c] -> p end), fn [written | _] ->
      written == name
    end)
  end

  defp round_trip(lines) do
    ics = calendar(lines)
    {:ok, component} = ICalendar.parse(ics)
    {:ok, back} = component |> JCal.encode() |> JCal.decode()

    ICalendar.write(back)
  end

  describe "value types" do
    # The type is the one thing iCalendar leaves implicit, and jCal
    # states on every line. Getting it from the property name is what
    # makes the mapping mechanical rather than a guess per document.
    test "a date-time is written in RFC 3339 punctuation", _context do
      assert ["dtstamp", %{}, "date-time", "2005-12-22T20:59:53Z"] =
               property(["BEGIN:VEVENT", "DTSTAMP:20051222T205953Z", "END:VEVENT"], "dtstamp")
    end

    test "a UTC offset gains its colon", _context do
      assert ["tzoffsetto", %{}, "utc-offset", "-05:00"] =
               property(["BEGIN:VTIMEZONE", "TZOFFSETTO:-0500", "END:VTIMEZONE"], "tzoffsetto")
    end

    test "an integer is a number, not a string", _context do
      assert ["sequence", %{}, "integer", 3] =
               property(["BEGIN:VEVENT", "SEQUENCE:3", "END:VEVENT"], "sequence")
    end

    test "a recurrence rule becomes an object with typed parts", _context do
      assert ["rrule", %{}, "recur", parts] =
               property(
                 ["BEGIN:VEVENT", "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10", "END:VEVENT"],
                 "rrule"
               )

      assert parts == %{"freq" => "YEARLY", "byday" => ["-1SU"], "bymonth" => [10]}
    end

    test "a period is the two halves it names", _context do
      assert ["freebusy", %{}, "period", ["2026-01-01T10:00:00Z", "PT1H"]] =
               property(
                 ["BEGIN:VFREEBUSY", "FREEBUSY:20260101T100000Z/PT1H", "END:VFREEBUSY"],
                 "freebusy"
               )
    end

    # RFC 7265 section 3.4.1. A server that refused what it did not
    # recognise could not carry an `X-` property at all, and clients
    # put a great deal in them.
    test "an unrecognised property is unknown rather than an error", _context do
      assert ["x-lic-location", %{}, "unknown", "Europe/Berlin"] =
               property(
                 ["BEGIN:VTIMEZONE", "X-LIC-LOCATION:Europe/Berlin", "END:VTIMEZONE"],
                 "x-lic-location"
               )
    end

    # `VALUE` states the type in iCalendar and is the type in jCal, so
    # carrying it as a parameter as well would say it twice.
    test "a VALUE parameter becomes the type and leaves the parameters", _context do
      assert ["dtstart", %{}, "date", "2026-01-01"] =
               property(
                 ["BEGIN:VEVENT", "DTSTART;VALUE=DATE:20260101", "END:VEVENT"],
                 "dtstart"
               )
    end

    test "other parameters stay, lowercased", _context do
      assert ["dtstart", %{"tzid" => "US/Eastern"}, "date-time", _value] =
               property(
                 ["BEGIN:VEVENT", "DTSTART;TZID=US/Eastern:20260101T100000", "END:VEVENT"],
                 "dtstart"
               )
    end
  end

  describe "reading it back" do
    test "a round trip leaves the calendar as it was", _context do
      lines = [
        "BEGIN:VEVENT",
        "UID:one",
        "DTSTART;TZID=US/Eastern:20260101T100000",
        "DURATION:PT1H",
        "SEQUENCE:2",
        "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10",
        "SUMMARY:event",
        "END:VEVENT"
      ]

      assert round_trip(lines) == calendar(lines)
    end

    # A JSON object has no order, so a rule reassembled in whatever
    # order the parser handed over would differ from the same rule
    # written by anybody else — and the value is compared as a string
    # once it is iCalendar again.
    test "a recurrence rule comes back in RFC 5545's order", _context do
      jcal =
        ~s([\"vcalendar\",[],[[\"vevent\",[[\"rrule\",{},\"recur\",) <>
          ~s({\"bymonth\":[10],\"byday\":[\"-1SU\"],\"freq\":\"YEARLY\"}]],[]]]])

      {:ok, component} = JCal.decode(jcal)

      assert ICalendar.write(component) =~ "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10"
    end

    test "a type that is the property's default needs no VALUE parameter", _context do
      {:ok, component} =
        JCal.decode(~s([\"vcalendar\",[],[[\"vevent\",[[\"uid\",{},\"text\",\"one\"]],[]]]]))

      assert ICalendar.write(component) =~ "UID:one\r\n"
    end

    test "a type that is not the default comes back as one", _context do
      {:ok, component} =
        JCal.decode(
          ~s([\"vcalendar\",[],[[\"vevent\",[[\"dtstart\",{},\"date\",\"2026-01-01\"]],[]]]])
        )

      assert ICalendar.write(component) =~ "DTSTART;VALUE=DATE:20260101"
    end

    test "a document that is JSON but not jCal is malformed", _context do
      assert JCal.decode(~s({"vcalendar": []})) == {:error, :malformed}
      assert JCal.decode(~s(["vcalendar"])) == {:error, :malformed}
    end
  end

  describe "which syntax the client wants" do
    defp offered(accept) do
      calendar = %Resource{collection?: true, types: [Cal.calendar()]}
      object = %Resource{path: ["c", "1.ics"]}

      JCal.offered(object, calendar, calendar([]), "text/calendar", accept, %{})
    end

    test "asking for jCal alone gets jCal", _context do
      assert {:ok, "application/calendar+json", _body} = offered(["application/calendar+json"])
    end

    test "asking for iCalendar alone gets what is stored", _context do
      assert offered(["text/calendar"]) == :skip
    end

    # RFC 9110's weights. A client that lists both and weights one
    # higher has said which it would rather have, and answering by
    # list order instead would ignore the only thing it stated.
    test "a heavier weight wins over position", _context do
      assert {:ok, "application/calendar+json", _body} =
               offered(["text/calendar;q=0.5, application/calendar+json;q=0.9"])
    end

    test "without weights the first named wins", _context do
      assert offered(["text/calendar, application/calendar+json"]) == :skip

      assert {:ok, "application/calendar+json", _body} =
               offered(["application/calendar+json, text/calendar"])
    end

    # A client that will take anything has expressed no preference,
    # and the stored syntax is the one to send.
    test "a wildcard is not a request for jCal", _context do
      assert offered(["*/*"]) == :skip
    end
  end
end
