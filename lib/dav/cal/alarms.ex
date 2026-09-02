defmodule Dav.Cal.Alarms do
  @moduledoc """
  Apple's default alarms — the reminder a calendar puts on what it is
  given.

  A calendar home, or a single calendar, states the alarm it wants on
  events stored without one:

      <C:default-alarm-vevent-datetime>
        BEGIN:VALARM
        TRIGGER:-PT15M
        ACTION:DISPLAY
        DESCRIPTION:Event reminder
        END:VALARM
      </C:default-alarm-vevent-datetime>

  There are four such properties — `VEVENT` and `VTODO`, each for
  timed and all-day components — and a calendar's own answer overrides
  the home's. `ACTION:NONE` is how a client says "no alarm here",
  which is different from saying nothing.

  The value is calendar data, so it is checked when it is set: a
  property holding something that is not a `VALARM` is refused rather
  than stored and applied to nothing.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @calendar_type "text/calendar; charset=utf-8"

  @kinds ~w(default-alarm-vevent-datetime default-alarm-vevent-date
            default-alarm-vtodo-datetime default-alarm-vtodo-date)

  @doc """
  Default alarms apply to calendars and to the home above them.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for any collection — the properties live on calendars and
    on calendar homes alike.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{collection?: true}), do: true
  def applies?(_absent), do: false

  @doc """
  Whether a default-alarm property may be set to this value.

  ### Arguments

  * `resource` is the resource being patched, unused.

  * `instruction` is one parsed instruction.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`, or `{:error, condition}` naming `CALDAV:valid-calendar-data`
    when the value is not a `VALARM`.

  """
  @impl Dav.Web.Hook
  @spec patchable(Resource.t(), tuple(), map()) :: :ok | {:error, Xml.qname()}
  def patchable(_resource, {:set, {namespace, name}, value}, _options)
      when name in @kinds do
    if namespace == Xml.caldav() and alarm?(value),
      do: :ok,
      else: {:error, {Xml.caldav(), "valid-calendar-data"}}
  end

  def patchable(_resource, _instruction, _options), do: :ok

  # An empty value is a client clearing the property, which is not the
  # same as writing nonsense into it.
  defp alarm?(value) when is_binary(value) do
    trimmed = String.trim(value)

    trimmed == "" or
      match?({:ok, %{name: "VALARM"}}, ICalendar.parse(trimmed)) or
      String.contains?(trimmed, "BEGIN:VALARM")
  end

  defp alarm?(_unreadable), do: false

  @doc """
  Put the collection's default alarm on what was just stored.

  ### Arguments

  * `change` carries the written `:resource`, its `:body` and the
    `:collection` it went into.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, whether or not an alarm was added.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(%{resource: resource, collection: collection}, options) do
    # Read what is stored rather than what was sent: an earlier hook
    # may have rewritten the body — scheduling canonicalises addresses
    # — and writing the client's copy back would undo it.
    with true <- Cal.calendar?(collection),
         {:ok, held} <- held(resource, options),
         {:ok, calendar} <- ICalendar.parse(held),
         {:ok, alarmed} <- alarmed(calendar, collection, options) do
      store(resource, alarmed, options)
    end

    :ok
  end

  def written(_change, _options), do: :ok

  defp held(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, body} <- store.read(resource, context) do
      {:ok, IO.iodata_to_binary(body)}
    else
      _unreadable -> :error
    end
  end

  # Only a component that carries no alarm of its own takes the
  # collection's: a client that said what it wanted has said it.
  defp alarmed(calendar, collection, options) do
    components =
      Enum.map(calendar.components, fn component ->
        with true <- component.name in ~w(VEVENT VTODO),
             [] <- Enum.filter(component.components, &(&1.name == "VALARM")),
             %{} = alarm <- default_for(component, collection, options) do
          %{component | components: component.components ++ [marked(alarm)]}
        else
          _alarmed_already_or_undefaulted -> component
        end
      end)

    if components == calendar.components,
      do: :none,
      else: {:ok, %{calendar | components: components}}
  end

  # The calendar's own answer first, then the home's — a calendar that
  # states nothing inherits, and one that states `ACTION:NONE` does
  # not.
  defp default_for(component, collection, options) do
    name = kind_of(component)

    Enum.find_value([collection, home_of(collection, options)], fn holder ->
      with %Resource{} <- holder,
           value when is_binary(value) <- stated(holder, name, options),
           {:ok, alarm} <- ICalendar.parse(String.trim(value)),
           true <- alarm.name == "VALARM",
           false <- silent?(alarm) do
        alarm
      else
        _unstated_or_silent -> nil
      end
    end)
  end

  defp kind_of(component) do
    part = if component.name == "VTODO", do: "vtodo", else: "vevent"
    "default-alarm-" <> part <> "-" <> if(dated?(component), do: "date", else: "datetime")
  end

  # An alarm the server put there says so, so a client can tell its
  # own reminder from the one the calendar supplied.
  defp marked(alarm) do
    if Enum.any?(alarm.properties, &(&1.name == "X-APPLE-DEFAULT-ALARM")) do
      alarm
    else
      stamp = %{name: "X-APPLE-DEFAULT-ALARM", parameters: %{}, value: "TRUE"}
      %{alarm | properties: alarm.properties ++ [stamp]}
    end
  end

  # An all-day component is one whose start is a date. The two have
  # their own defaults because a reminder fifteen minutes before a
  # date means nothing.
  defp dated?(component) do
    case Enum.find(component.properties, &(&1.name == "DTSTART")) do
      %{value: value, parameters: parameters} ->
        Map.get(parameters, "VALUE") == "DATE" or not String.contains?(value, "T")

      nil ->
        false
    end
  end

  # `ACTION:NONE` is a statement, not an omission: this collection
  # wants no alarm, and the home's is not consulted.
  defp silent?(alarm) do
    Enum.any?(alarm.properties, &(&1.name == "ACTION" and String.upcase(&1.value) == "NONE"))
  end

  defp stated(holder, name, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(holder, context) do
      Map.get(properties, {Xml.caldav(), name})
    else
      _none -> nil
    end
  end

  defp home_of(%Resource{path: [_head | _tail] = path}, %{store: store, context: context}) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, %Resource{collection?: true} = home} -> home
      _nowhere -> nil
    end
  end

  defp home_of(_collection, _options), do: nil

  defp store(resource, calendar, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      store.put(resource.path, ICalendar.write(calendar), @calendar_type, context)
    end
  end
end
