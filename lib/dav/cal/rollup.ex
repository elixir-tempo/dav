defmodule Dav.Cal.Rollup do
  @moduledoc """
  A calendar collection rendered as one iCalendar object, for `GET`.

  Apple's CalendarServer answers a `GET` on a calendar collection with
  the whole calendar rolled into a single `VCALENDAR`: every member's
  components merged, timezones stated once, and each member shown as
  the caller is allowed to see it — a private event missing entirely,
  a confidential one reduced to its timing. This module offers that
  rendering through `c:Dav.Web.Hook.rendered/2`; collections that are
  not calendars are left to the `405` they had before.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @access "X-CALENDARSERVER-ACCESS"
  @calendar_name "X-WR-CALNAME"
  @calendar_type "text/calendar; charset=utf-8"

  @doc """
  Rollup applies to calendar collections.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for a calendar.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(collection), do: Cal.calendar?(collection)

  @doc """
  Render a calendar collection as a single iCalendar object.

  ### Arguments

  * `collection` is the resolved collection.

  * `options` carries `:store`, `:context`, `:principal` and `:hooks`.

  ### Returns

  * `{:ok, content_type, body}` for a calendar, or `:skip` for any
    other collection.

  """
  @impl Dav.Web.Hook
  @spec rendered(Resource.t(), map()) :: {:ok, String.t(), binary()} | :skip
  def rendered(%Resource{collection?: true} = collection, options) do
    if Cal.calendar?(collection) and Store.supports?(options.store, :read),
      do: {:ok, @calendar_type, rolled(collection, options)},
      else: :skip
  end

  def rendered(_resource, _options), do: :skip

  @doc """
  A write changes nothing the rollup keeps — it is rendered afresh on
  every read.

  ### Arguments

  * `change` is the write, unused.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  # Each member is read the way a `GET` on it would be — through
  # every hook's `disclosed/3` — so a member the caller may not see
  # falls out here, and a filtered one arrives already filtered.
  defp rolled(collection, %{store: store, context: context} = options) do
    calendars =
      for member <- members(collection, options),
          {:ok, held} <- [store.read(member, context)],
          {:ok, body} <- [Hook.disclosure(member, IO.iodata_to_binary(held), options)],
          {:ok, calendar} <- [ICalendar.parse(body)],
          do: calendar

    calendars |> merged() |> named(collection, options) |> ICalendar.write()
  end

  # `X-WR-CALNAME` is what every client shows this file as once it has
  # been saved or subscribed to, and the collection's `DAV:displayname`
  # is the only name it has. Without it the calendar arrives called
  # whatever the file was called, which for a rollup is nothing.
  defp named(calendar, collection, options) do
    case display_name(collection, options) do
      nil ->
        calendar

      name ->
        stated = %{name: @calendar_name, parameters: %{}, value: name}

        %{
          calendar
          | properties: Enum.reject(calendar.properties, &(&1.name == @calendar_name)) ++ [stated]
        }
    end
  end

  # The stored property first, then whatever the resource says it is
  # called: a client that renamed the calendar has said so by storing
  # `DAV:displayname`, and that answer outranks the derived one.
  defp display_name(collection, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :properties),
         %{} = stored <- store.properties(collection, context),
         name when is_binary(name) <- Map.get(stored, {Xml.dav(), "displayname"}) do
      name
    else
      _unstored -> named_by(collection, options)
    end
  end

  defp named_by(%Resource{display_name: name}, _options) when is_binary(name), do: name
  defp named_by(_collection, _options), do: nil

  defp members(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.reject(children, & &1.collection?)
      _nothing -> []
    end
  end

  # One calendar out of many: timezones stated once each, every other
  # component carried over. The access marks are each member's own
  # story, and one member's mark said nothing about the rest — so
  # none of them survives the merge.
  defp merged([]), do: empty()

  defp merged([first | _rest] = calendars) do
    components = Enum.flat_map(calendars, & &1.components)
    zones = components |> Enum.filter(&(&1.name == "VTIMEZONE")) |> Enum.uniq_by(&tzid/1)
    objects = Enum.reject(components, &(&1.name == "VTIMEZONE"))

    %{
      first
      | properties: Enum.reject(first.properties, &(&1.name == @access)),
        components: zones ++ objects
    }
  end

  defp empty do
    %{
      name: "VCALENDAR",
      properties: [%{name: "VERSION", parameters: %{}, value: "2.0"}],
      components: []
    }
  end

  defp tzid(component) do
    Enum.find_value(component.properties, fn
      %{name: "TZID", value: value} -> value
      _other -> nil
    end)
  end
end
