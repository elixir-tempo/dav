defmodule Dav.Cal.FilterTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.Filter
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
      assert event.time_range == {"20260601T000000Z", "20260701T000000Z"}
    end

    test "a time range may be open at either end" do
      {:ok, filter} =
        parse(
          ~s(<C:comp-filter name="VCALENDAR"><C:time-range start="20260601T000000Z"/></C:comp-filter>)
        )

      assert filter.time_range == {"20260601T000000Z", nil}
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
end
