defmodule Dav.Cal.AlarmsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Test.SchedulingStore
  alias Dav.Web.Plug, as: DavPlug
  alias Dav.Web.Resource

  setup do
    agent =
      SchedulingStore.start(
        [
          %Resource{path: [], collection?: true},
          %Resource{path: ["alice"], collection?: true, owner: "/principals/alice/"},
          %Resource{
            path: ["alice", "calendar"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/principals/alice/"
          }
        ],
        %{"mailto:alice@example.com" => ["alice"]}
      )

    %{options: DavPlug.init(store: SchedulingStore, context: agent, hooks: [Cal.Alarms])}
  end

  defp alarm(trigger) do
    ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Test", "TRIGGER:#{trigger}", "END:VALARM"]
  end

  defp event(alarms) do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:alarmed",
        "SUMMARY:Alarmed",
        "DTSTART:20271215T090000Z"
      ] ++ alarms ++ ["END:VEVENT", "END:VCALENDAR"],
      "\r\n"
    ) <> "\r\n"
  end

  defp stored(alarms, context) do
    DavPlug.call(conn("PUT", "/alice/calendar/a.ics", event(alarms)), context.options)

    DavPlug.call(conn("GET", "/alice/calendar/a.ics", ""), context.options).resp_body
  end

  defp triggers(body) do
    body
    |> String.replace("\r\n ", "")
    |> String.split("\r\n")
    |> Enum.filter(&String.starts_with?(&1, "TRIGGER"))
  end

  describe "alarms on a stored event" do
    test "the same alarm sent twice is kept once", context do
      body = stored(alarm("-PT10M") ++ alarm("-PT5M") ++ alarm("-PT10M"), context)

      # A client that sent the same reminder twice meant one reminder.
      # The repeat goes where it stands, so the first stays put and
      # the order the client chose survives.
      assert triggers(body) == ["TRIGGER:-PT10M", "TRIGGER:-PT5M"]
    end

    test "two alarms that differ are both kept", context do
      body = stored(alarm("-PT10M") ++ alarm("-PT5M"), context)

      assert triggers(body) == ["TRIGGER:-PT10M", "TRIGGER:-PT5M"]
    end

    test "an event with one alarm is left alone", context do
      assert triggers(stored(alarm("-PT10M"), context)) == ["TRIGGER:-PT10M"]
    end
  end
end
