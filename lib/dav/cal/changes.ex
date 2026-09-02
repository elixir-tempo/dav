defmodule Dav.Cal.Changes do
  @moduledoc """
  Apple's `CS:schedule-changes` — what a delivered message actually
  changed.

  An iTIP message says what the event *is*; it does not say what is
  different about it. A client showing an Inbox full of updates has to
  diff each one against the copy it already holds to tell "the time
  moved" from "somebody accepted". The reference does that work on the
  server and records it beside the message:

      <CS:schedule-changes>
        <CS:action>
          <CS:update>
            <CS:recurrence>
              <CS:master/>
              <CS:changes>
                <CS:changed-property name="DTSTART"/>
              </CS:changes>
            </CS:recurrence>
          </CS:update>
        </CS:action>
      </CS:schedule-changes>

  Four actions are described: `create` for a message about something
  the recipient does not hold, `update` for one that changes what they
  do, `cancel` for a withdrawal, and `reply` for an answer — which
  also names the attendee who sent it.

  """

  alias Dav.Cal.ICalendar
  alias Dav.Cal.Scheduling

  @namespace "http://calendarserver.org/ns/"

  # Bookkeeping the server maintains on every write. Reporting these as
  # changes would tell a client that a stamp moved, which is true of
  # every message and interesting in none.
  @incidental ~w(DTSTAMP SEQUENCE X-CALENDARSERVER-DTSTAMP LAST-MODIFIED CREATED
                 SCHEDULE-STATUS SCHEDULE-AGENT REQUEST-STATUS)

  @doc """
  Describe what a message does to the copy its recipient holds.

  ### Arguments

  * `method` is the iTIP method — `"REQUEST"`, `"REPLY"` or
    `"CANCEL"`.

  * `told` are the message's components.

  * `held` are the components of the recipient's copy as it stood
    before this message, or `[]` when they hold none.

  * `sender` is the address the message came from, used to name the
    attendee an answer is from.

  ### Returns

  * The property's value, as a `t:Dav.Xml.value/0` carrying markup.

  ### Examples

      iex> {:elements, _namespaces, markup} = Dav.Cal.Changes.describe("REQUEST", [], [], nil)
      iex> String.contains?(markup, "<CS:create/>")
      true

  """
  @spec describe(String.t(), [ICalendar.component()], [ICalendar.component()], String.t() | nil) ::
          Dav.Xml.value()
  def describe(method, told, held, sender) do
    inner =
      ~s(<CS:action xmlns:CS=") <>
        @namespace <> ~s(">) <> action(method, told, held, sender) <> "</CS:action>"

    {:elements, [@namespace], inner}
  end

  # A reply answers; a cancel withdraws; anything else either creates
  # what the recipient does not hold or updates what they do.
  defp action("REPLY", told, held, sender) do
    "<CS:reply>" <> attendee(sender) <> recurrences(told, held, :answered) <> "</CS:reply>"
  end

  defp action("CANCEL", told, _held, _sender) do
    "<CS:cancel>" <> Enum.map_join(dated(told), &named_recurrence/1) <> "</CS:cancel>"
  end

  defp action(_request, _told, [], _sender), do: "<CS:create/>"

  defp action(_request, told, held, _sender) do
    "<CS:update>" <> recurrences(told, held, :stated) <> "</CS:update>"
  end

  defp attendee(nil), do: ""
  defp attendee(sender), do: "<CS:attendee>" <> escaped(sender) <> "</CS:attendee>"

  # One entry per component the message speaks about, naming which
  # occurrence it is and what differs in it.
  defp recurrences(told, held, kind) do
    spoken =
      Enum.map_join(dated(told), fn component ->
        "<CS:recurrence>" <>
          which(component) <>
          changes(component, counterpart(component, held), kind) <> "</CS:recurrence>"
      end)

    spoken <> implied(told, held, kind)
  end

  # A message about the series is a message about each of its
  # occurrences. Where the recipient holds overrides the message does
  # not name, they are affected all the same — an answer to the master
  # answers for them, and a change to it changes them — so each is
  # named with what the master's own change was.
  defp implied(told, held, kind) do
    case Enum.find(dated(told), &is_nil(value(&1, "RECURRENCE-ID"))) do
      nil ->
        ""

      master ->
        named = for component <- dated(told), do: value(component, "RECURRENCE-ID")

        for override <- dated(held),
            rid = recurrence_id(override),
            not is_nil(rid),
            rid not in named,
            into: "",
            do:
              "<CS:recurrence><CS:recurrenceid>" <>
                escaped(rid) <>
                "</CS:recurrenceid>" <>
                changes(master, counterpart(master, held), kind) <>
                "</CS:recurrence>"
    end
  end

  defp named_recurrence(component) do
    "<CS:recurrence>" <> which(component) <> "</CS:recurrence>"
  end

  # The master carries no `RECURRENCE-ID`; an override is named by the
  # occurrence it replaces.
  defp which(component) do
    case recurrence_id(component) do
      nil -> "<CS:master/>"
      rid -> "<CS:recurrenceid>" <> escaped(rid) <> "</CS:recurrenceid>"
    end
  end

  # Named as the rest of the server names occurrences: in UTC, so a
  # client matching this against its own copy compares one spelling.
  defp recurrence_id(component) do
    case Enum.find(component.properties, &(&1.name == "RECURRENCE-ID")) do
      nil -> nil
      property -> Scheduling.utc_form(property.value, property.parameters)
    end
  end

  # What differs, property by property. A component the recipient did
  # not hold before is wholly new, and saying every one of its
  # properties changed tells them nothing they cannot see; the element
  # is written empty, which is what the reference does.
  defp changes(_component, nil, _kind), do: "<CS:changes/>"

  defp changes(component, previous, kind) do
    differing =
      for name <- names(component, previous),
          name not in @incidental,
          markup = property_change(name, component, previous, kind),
          markup != nil,
          do: markup

    if differing == [],
      do: "<CS:changes/>",
      else: "<CS:changes>" <> Enum.join(differing) <> "</CS:changes>"
  end

  defp names(component, previous) do
    for property <- component.properties ++ previous.properties, uniq: true, do: property.name
  end

  # A property counts as changed when it appears, disappears, or is
  # written differently — and when only its parameters moved, the ones
  # that moved are named inside it: an `ATTENDEE` whose `PARTSTAT`
  # went from `NEEDS-ACTION` to `ACCEPTED` is somebody answering, not
  # somebody being added.
  defp property_change(name, component, previous, kind) do
    told = lines(component, name)
    held = lines(previous, name)

    cond do
      told == held -> nil
      gained_or_lost?(told, held, kind) -> changed_property(name, [])
      true -> parameter_change(name, told, held)
    end
  end

  # A property may be written more than once — every `ATTENDEE` on a
  # meeting — so lines are matched by value rather than by position: a
  # reply carries one attendee's line where the copy holds five, and
  # pairing them in order compares one person's answer with another's.
  # An answer speaks only of the lines it carries; anything else is
  # its sender staying silent, not a removal.
  defp gained_or_lost?(told, held, :answered) do
    Enum.any?(told, &(by_value(held)[&1.value] == nil))
  end

  defp gained_or_lost?(told, held, :stated) do
    values_of(told) -- values_of(held) != [] or values_of(held) -- values_of(told) != []
  end

  defp parameter_change(name, told, held) do
    was = by_value(held)

    moved =
      for line <- told,
          previous = was[line.value],
          previous != nil,
          parameter <- Map.keys(line.parameters) ++ Map.keys(previous),
          Map.get(line.parameters, parameter) != Map.get(previous, parameter),
          uniq: true,
          do: parameter

    if moved == [], do: nil, else: changed_property(name, moved)
  end

  defp by_value(properties) do
    for property <- properties, into: %{}, do: {property.value, property.parameters}
  end

  defp changed_property(name, parameters) do
    inner =
      Enum.map_join(parameters, &(~s(<CS:changed-parameter name=") <> escaped(&1) <> ~s(" />)))

    if inner == "",
      do: ~s(<CS:changed-property name=") <> escaped(name) <> ~s(" />),
      else:
        ~s(<CS:changed-property name=") <>
          escaped(name) <> ~s(">) <> inner <> "</CS:changed-property>"
  end

  defp lines(component, name), do: Enum.filter(component.properties, &(&1.name == name))
  defp values_of(properties), do: Enum.map(properties, & &1.value)

  defp counterpart(component, held) do
    Enum.find(held, &(value(&1, "RECURRENCE-ID") == value(component, "RECURRENCE-ID")))
  end

  defp dated(components) do
    Enum.reject(components, &(&1.name == "VTIMEZONE"))
  end

  defp value(component, name) do
    case Enum.find(component.properties, &(&1.name == name)) do
      nil -> nil
      property -> property.value
    end
  end

  defp escaped(text) do
    text |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
  end
end
