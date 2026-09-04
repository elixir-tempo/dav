defmodule Dav.Cal.Selection do
  @moduledoc """
  Returning part of a calendar object — RFC 4791 section 9.6.

  A `CALDAV:calendar-data` element in a report's `DAV:prop` may carry
  `CALDAV:comp` and `CALDAV:prop` children naming what the client
  wants back:

      <C:calendar-data>
        <C:comp name="VCALENDAR">
          <C:comp name="VEVENT">
            <C:prop name="SUMMARY"/>
            <C:prop name="UID"/>
          </C:comp>
          <C:comp name="VTIMEZONE"/>
        </C:comp>
      </C:calendar-data>

  Sending the whole object instead is not a harmless generosity. A
  client asking for two properties of each event, over a month of a
  busy calendar, is asking for a few kilobytes; answering with every
  `DESCRIPTION` and `ATTACH` can be megabytes, over a mobile
  connection, for data it will discard. It is also a privacy
  boundary — a `free-busy`-style client asking only for times should
  not be handed the subject lines.

  ### An empty selection means everything

  `<C:calendar-data/>` with no children asks for the object as stored,
  which is the common case and stays a straight copy.

  """

  alias Dav.Cal.ICalendar
  alias Dav.Xml

  @typedoc "What to keep, or `:everything`."
  @type t :: :everything | %{optional(String.t()) => component_selection()}

  @typedoc "One component's selection: which sub-components and properties."
  @type component_selection :: %{
          components: t(),
          properties: :everything | MapSet.t()
        }

  @doc """
  Whether the client asked for calendar data this server can return.

  `CALDAV:calendar-data` may carry `content-type` and `version`
  attributes naming the form the client wants back. Two forms are
  returned — iCalendar 2.0 and RFC 7265's jCal — and a client that
  asked for a third would mis-parse every object rather than fail
  cleanly, so the request is refused instead.

  ### Arguments

  * `element` is the `calendar-data` element, or `nil`.

  ### Returns

  * `:ok`, or `{:error, precondition}`.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav" content-type="application/calendar+json"/>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Selection.supported(element)
      :ok

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav" content-type="text/vcard"/>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Selection.supported(element)
      {:error, {"urn:ietf:params:xml:ns:caldav", "supported-calendar-data"}}

  """
  @spec supported(Xml.element() | nil) :: :ok | {:error, Xml.qname()}
  def supported(nil), do: :ok

  def supported(element) do
    version = Map.get(element.attributes, "version", "2.0")

    if syntax(element) != :unsupported and version == "2.0" do
      :ok
    else
      {:error, {Xml.caldav(), "supported-calendar-data"}}
    end
  end

  @doc """
  Which syntax the client asked the calendar data back in.

  ### Arguments

  * `element` is the `calendar-data` element, or `nil`.

  ### Returns

  * `:icalendar`, `:jcal`, or `:unsupported` for a media type this
    server does not write.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav" content-type="application/calendar+json"/>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Selection.syntax(element)
      :jcal

      iex> Dav.Cal.Selection.syntax(nil)
      :icalendar

  """
  @spec syntax(Xml.element() | nil) :: :icalendar | :jcal | :unsupported
  def syntax(nil), do: :icalendar

  def syntax(element) do
    case Map.get(element.attributes, "content-type", "text/calendar") do
      "text/calendar" -> :icalendar
      "application/calendar+json" -> :jcal
      _another_server_writes_it -> :unsupported
    end
  end

  @doc """
  Read a selection from a `CALDAV:calendar-data` element.

  ### Arguments

  * `element` is the `calendar-data` element from the request, or
    `nil` when the client did not ask for calendar data at all.

  ### Returns

  * `:everything` when no sub-setting was requested; or

  * a map from component name to what to keep of it.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"/>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> Dav.Cal.Selection.from_element(element)
      :everything

      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp name="VCALENDAR"><C:comp name="VEVENT"><C:prop name="UID"/></C:comp></C:comp></C:calendar-data>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> selection = Dav.Cal.Selection.from_element(element)
      iex> Map.keys(selection)
      ["VCALENDAR"]

  """
  @spec from_element(Xml.element() | nil) :: t()
  def from_element(nil), do: :everything

  def from_element(element) do
    case components(element) do
      [] -> :everything
      chosen -> Map.new(chosen, &{name_of(&1), selection(&1)})
    end
  end

  defp selection(element) do
    %{
      components: from_element(element),
      properties: properties(element)
    }
  end

  # A `comp` naming no properties wants all of them; one naming some
  # wants exactly those.
  defp properties(element) do
    case for(child <- element.children, local?(child, "prop"), do: name_of(child)) do
      [] -> :everything
      chosen -> MapSet.new(chosen)
    end
  end

  defp components(element), do: Enum.filter(element.children, &local?(&1, "comp"))

  defp name_of(element), do: Map.get(element.attributes, "name", "")

  defp local?(%{name: {_namespace, local}}, local), do: true
  defp local?(_element, _local), do: false

  @doc """
  Apply a selection to a calendar object.

  ### Arguments

  * `data` is the object as stored.

  * `selection` is a `t:t/0`.

  ### Returns

  * The object, or the requested part of it, as iCalendar text. Data
    that cannot be parsed is returned unchanged rather than dropped —
    a selection is a request to send less, not a reason to send
    nothing.

  ### Examples

      iex> ics = "BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nUID:1\\r\\nSUMMARY:Hi\\r\\nDESCRIPTION:Long\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n"
      iex> body = ~s(<?xml version="1.0"?><C:calendar-data xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp name="VCALENDAR"><C:comp name="VEVENT"><C:prop name="UID"/></C:comp></C:comp></C:calendar-data>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> kept = Dav.Cal.Selection.apply(ics, Dav.Cal.Selection.from_element(element))
      iex> {String.contains?(kept, "UID:1"), String.contains?(kept, "DESCRIPTION")}
      {true, false}

  """
  @spec apply(binary(), t()) :: binary()
  def apply(data, :everything), do: data

  def apply(data, selection) do
    case ICalendar.parse(data) do
      {:ok, calendar} -> calendar |> keep(selection) |> write()
      _unreadable -> data
    end
  end

  defp keep(component, selection) do
    case Map.fetch(selection, component.name) do
      :error -> nil
      {:ok, wanted} -> prune(component, wanted)
    end
  end

  defp prune(component, wanted) do
    %{
      name: component.name,
      properties: chosen_properties(component, wanted.properties),
      components: chosen_components(component, wanted.components)
    }
  end

  defp chosen_properties(component, :everything), do: component.properties

  defp chosen_properties(component, wanted),
    do: Enum.filter(component.properties, &MapSet.member?(wanted, &1.name))

  defp chosen_components(component, :everything), do: component.components

  defp chosen_components(component, wanted),
    do: component.components |> Enum.map(&keep(&1, wanted)) |> Enum.reject(&is_nil/1)

  defp write(nil), do: ""

  # `Dav.Cal.ICalendar.write/1` re-escapes values, which matters here:
  # the reader turned `\\n` into a newline, and writing that back raw
  # would end the object at the first multi-line DESCRIPTION.
  defp write(component), do: ICalendar.write(component)
end
