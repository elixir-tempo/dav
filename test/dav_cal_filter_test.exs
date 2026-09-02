defmodule Dav.Cal.FilterTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.Filter
  alias Dav.Cal.ICalendar
  alias Dav.Cal.TimeRange
  alias Dav.Xml

  doctest Dav.Cal.Filter

  defp parse(inner) do
    body =
      ~s(<C:filter xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:D="DAV:">#{inner}</C:filter>)

    {:ok, element} = Xml.parse(body)
    Filter.from_element(element)
  end

  describe "the shape of a filter" do
    test "nests to mirror the calendar data it selects" do
      {:ok, filter} =
        parse("""
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:time-range start="20260601T000000Z" end="20260701T000000Z"/>
          </C:comp-filter>
        </C:comp-filter>
        """)

      assert filter.name == "VCALENDAR"
      assert [event] = filter.children
      assert event.name == "VEVENT"
      assert {:ok, window} = TimeRange.bounds({"20260601T000000Z", "20260701T000000Z"})
      assert event.time_range == window
    end

    test "a time range may be open at either end" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:time-range start="20260601T000000Z"/></C:comp-filter>)
        )

      assert {:ok, window} = TimeRange.bounds({"20260601T000000Z", nil})
      assert filter.time_range == window
    end

    test "the grammar allows exactly one comp-filter in a filter" do
      assert {:error, :malformed} = parse("")

      assert {:error, :malformed} =
               parse(~s(<C:comp-filter name="A"/><C:comp-filter name="B"/>))
    end
  end

  describe "is-not-defined" do
    test "marks a component as required to be absent" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"><C:is-not-defined/></C:comp-filter></C:comp-filter>)
        )

      assert [todo] = filter.children
      assert todo.undefined?
      refute filter.undefined?
    end
  end

  describe "prop and param filters" do
    test "are parsed to their own kinds, nested as the grammar allows" do
      {:ok, filter} =
        parse("""
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:prop-filter name="ATTENDEE">
              <C:text-match collation="i;ascii-casemap">kim@example.test</C:text-match>
              <C:param-filter name="PARTSTAT">
                <C:text-match negate-condition="yes">DECLINED</C:text-match>
              </C:param-filter>
            </C:prop-filter>
          </C:comp-filter>
        </C:comp-filter>
        """)

      [event] = filter.children
      [attendee] = event.children

      assert attendee.kind == :prop
      assert attendee.name == "ATTENDEE"
      assert attendee.text_match.value == "kim@example.test"
      refute attendee.text_match.negate?

      [partstat] = attendee.children
      assert partstat.kind == :param
      assert partstat.text_match.negate?
    end

    test "a text match defaults to the collation the specification names" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:prop-filter name="SUMMARY"><C:text-match>lunch</C:text-match></C:prop-filter></C:comp-filter>)
        )

      [summary] = filter.children
      assert summary.text_match.collation == "i;ascii-casemap"
      refute summary.text_match.negate?
    end
  end

  describe "tolerance" do
    test "an element the filter language does not define is ignored, not refused" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><D:invented/><C:comp-filter name="VEVENT"/></C:comp-filter>)
        )

      assert Enum.map(filter.children, & &1.name) == ["VEVENT"]
    end
  end

  describe "matching" do
    defp ics(lines), do: Enum.join(lines, "\r\n") <> "\r\n"

    defp calendar(lines) do
      {:ok, component} = ICalendar.parse(ics(lines))
      component
    end

    defp matches?(inner, lines, options \\ []) do
      {:ok, filter} = parse(inner)
      Filter.match?(filter, calendar(lines), options)
    end

    @event [
      "BEGIN:VCALENDAR",
      "BEGIN:VEVENT",
      "SUMMARY:Team lunch",
      "ATTENDEE;PARTSTAT=ACCEPTED:mailto:kim@example.test",
      "END:VEVENT",
      "END:VCALENDAR"
    ]

    test "a component filter asks whether the parent contains one" do
      assert matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"/></C:comp-filter>),
               @event
             )

      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter>),
               @event
             )
    end

    test "the outermost name must match the object itself" do
      refute matches?(~s(<C:comp-filter name="VTODO"/>), @event)
    end

    test "is-not-defined asks the opposite question" do
      assert matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"><C:is-not-defined/></C:comp-filter></C:comp-filter>),
               @event
             )

      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:is-not-defined/></C:comp-filter></C:comp-filter>),
               @event
             )
    end

    test "conditions at one level are conjunctive" do
      both =
        ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"/><C:comp-filter name="VTODO"/></C:comp-filter>)

      refute matches?(both, @event)
    end

    test "a property filter is satisfied by any property that matches" do
      assert matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="SUMMARY"/></C:comp-filter></C:comp-filter>),
               @event
             )

      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="LOCATION"/></C:comp-filter></C:comp-filter>),
               @event
             )
    end

    test "text-match is a substring test, and case-insensitive by default" do
      assert matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="SUMMARY"><C:text-match>LUNCH</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter>),
               @event
             )
    end

    test "negate-condition inverts the whole result" do
      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="SUMMARY"><C:text-match negate-condition="yes">lunch</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter>),
               @event
             )
    end

    test "an octet collation is case-sensitive" do
      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="SUMMARY"><C:text-match collation="i;octet">LUNCH</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter>),
               @event
             )
    end

    test "a parameter filter reaches into the property's parameters" do
      assert matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="ATTENDEE"><C:param-filter name="PARTSTAT"><C:text-match>ACCEPTED</C:text-match></C:param-filter></C:prop-filter></C:comp-filter></C:comp-filter>),
               @event
             )

      refute matches?(
               ~s(<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"><C:prop-filter name="ATTENDEE"><C:param-filter name="PARTSTAT"><C:text-match>DECLINED</C:text-match></C:param-filter></C:prop-filter></C:comp-filter></C:comp-filter>),
               @event
             )
    end
  end

  describe "time ranges" do
    test "raise without an evaluator rather than guessing" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:time-range start="20260601T000000Z"/></C:comp-filter>)
        )

      {:ok, calendar} = ICalendar.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")

      assert_raise ArgumentError, ~r/time-range/, fn -> Filter.match?(filter, calendar) end
    end

    test "are answered by the evaluator that is supplied" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:time-range start="20260601T000000Z" end="20260701T000000Z"/></C:comp-filter>)
        )

      {:ok, calendar} = ICalendar.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")

      assert Filter.match?(filter, calendar, time_range: fn _component, _range -> true end)
      refute Filter.match?(filter, calendar, time_range: fn _component, _range -> false end)
    end

    test "the evaluator is given the window already read" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:time-range start="20260601T000000Z" end="20260701T000000Z"/></C:comp-filter>)
        )

      {:ok, calendar} = ICalendar.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")

      {:ok, window} = TimeRange.bounds({"20260601T000000Z", "20260701T000000Z"})

      Filter.match?(filter, calendar,
        time_range: fn _component, range ->
          assert range == window
          true
        end
      )
    end
  end
end
