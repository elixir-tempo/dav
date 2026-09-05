defmodule Dav.Cal.TrashTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Dav.Cal
  alias Dav.Cal.Schedule
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
          },
          %Resource{path: ["alice", "inbox"], collection?: true, types: [Schedule.inbox()]},
          %Resource{path: ["bob"], collection?: true, owner: "/principals/bob/"},
          %Resource{
            path: ["bob", "calendar"],
            collection?: true,
            types: [Cal.calendar()],
            owner: "/principals/bob/"
          },
          %Resource{path: ["bob", "inbox"], collection?: true, types: [Schedule.inbox()]}
        ],
        %{"mailto:alice@example.com" => ["alice"], "mailto:bob@example.com" => ["bob"]}
      )

    options =
      DavPlug.init(
        store: SchedulingStore,
        context: agent,
        hooks: [Dav.Cal.Scheduling, Dav.Cal.Trash]
      )

    %{options: options}
  end

  defp meeting(attendees) do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "BEGIN:VEVENT",
        "UID:binned",
        "SUMMARY:Binned",
        "ORGANIZER:mailto:alice@example.com",
        "ATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@example.com"
      ] ++
        attendees ++ ["DTSTART:20271215T090000Z", "END:VEVENT", "END:VCALENDAR"],
      "\r\n"
    ) <> "\r\n"
  end

  defp recover(options) do
    DavPlug.call(conn("POST", "/alice/?action=recovertrash&mode=event&id=all", ""), options)
  end

  defp line_for(body, who) do
    body
    |> String.replace("\r\n ", "")
    |> String.split("\r\n")
    |> Enum.find("", &String.contains?(&1, who))
  end

  describe "recovering a trashed event" do
    test "puts an invitation back past the cancellation that withdrew it", context do
      DavPlug.call(
        conn("PUT", "/alice/calendar/b.ics", meeting(["ATTENDEE:mailto:bob@example.com"])),
        context.options
      )

      DavPlug.call(conn("DELETE", "/alice/calendar/b.ics", ""), context.options)

      assert recover(context.options).status == 200

      theirs =
        DavPlug.call(conn("GET", "/bob/calendar/binned.ics", ""), context.options).resp_body

      # Trashing the invitation sent a `CANCEL` numbered one past the
      # copy it withdrew. Putting the event back at its old number
      # would hand the attendee a `REQUEST` older than the
      # cancellation they hold, and a client that honours `SEQUENCE`
      # keeps the meeting struck through.
      assert line_for(theirs, "SEQUENCE") == "SEQUENCE:1"
    end

    test "leaves an event nobody was asked to exactly as it was", context do
      DavPlug.call(conn("PUT", "/alice/calendar/a.ics", meeting([])), context.options)
      DavPlug.call(conn("DELETE", "/alice/calendar/a.ics", ""), context.options)

      assert recover(context.options).status == 200

      restored =
        DavPlug.call(conn("GET", "/alice/calendar/a.ics", ""), context.options).resp_body

      # Nothing was cancelled when this went, so there is nothing to
      # outrank: numbering it on the way back would invent a revision
      # nobody made.
      assert restored =~ "SUMMARY:Binned"
      refute restored =~ "SEQUENCE:"
    end
  end
end
