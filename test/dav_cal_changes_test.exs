defmodule Dav.Cal.ChangesTest do
  use ExUnit.Case, async: true

  alias Dav.Cal.Changes
  alias Dav.Cal.ICalendar

  doctest Dav.Cal.Changes

  defp components(lines) do
    body =
      Enum.join(["BEGIN:VCALENDAR", "VERSION:2.0"] ++ lines ++ ["END:VCALENDAR"], "\r\n") <>
        "\r\n"

    {:ok, calendar} = ICalendar.parse(body)
    calendar.components
  end

  defp series(partstat) do
    components([
      "BEGIN:VEVENT",
      "UID:s",
      "DTSTART:20271201T090000Z",
      "RRULE:FREQ=DAILY;COUNT=3",
      "SUMMARY:Series",
      "ORGANIZER:mailto:alice@example.com",
      "ATTENDEE;PARTSTAT=#{partstat}:mailto:bob@example.com",
      "END:VEVENT"
    ])
  end

  defp answer_for(recurrence, partstat) do
    components([
      "BEGIN:VEVENT",
      "UID:s",
      "RECURRENCE-ID:#{recurrence}",
      "DTSTART:#{recurrence}",
      "SUMMARY:Series",
      "ORGANIZER:mailto:alice@example.com",
      "ATTENDEE;PARTSTAT=#{partstat}:mailto:bob@example.com",
      "END:VEVENT"
    ])
  end

  defp markup(method, told, held) do
    {:elements, _namespaces, markup} =
      Changes.describe(method, told, held, "mailto:bob@example.com")

    markup
  end

  describe "a reply about one occurrence of a series" do
    test "is described against the instance the rule implies", context do
      _ = context

      told = answer_for("20271202T090000Z", "ACCEPTED")
      held = series("NEEDS-ACTION")

      answered = markup("REPLY", told, held)

      # The organiser holds no component for this Tuesday — the rule
      # makes it. Treating the override as wholly new writes the
      # changes element empty, which tells the organiser a reply
      # arrived but not that anybody answered, and answering is the
      # whole of what a reply says.
      assert answered =~ ~s(<CS:recurrenceid>20271202T090000Z</CS:recurrenceid>)
      assert answered =~ ~s(changed-property name="ATTENDEE")
      assert answered =~ ~s(changed-parameter name="PARTSTAT")
    end

    test "still says nothing about an occurrence no rule of theirs makes", context do
      _ = context

      answered = markup("REPLY", answer_for("20271202T090000Z", "ACCEPTED"), [])

      # A recipient holding nothing at all is being told about a
      # meeting for the first time; naming every property as changed
      # would say nothing they cannot already see.
      refute answered =~ ~s(changed-property name="ATTENDEE")
    end
  end
end
