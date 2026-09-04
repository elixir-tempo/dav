defmodule Dav.Cal do
  @moduledoc """
  CalDAV — RFC 4791.

  Calendars over WebDAV. A calendar collection is an ordinary WebDAV
  collection that additionally reports `CALDAV:calendar` in its
  resource type, and the calendar objects inside it are ordinary
  resources whose bodies are iCalendar.

  Everything here reaches `Dav.Web` through the two seams it offers
  rather than by modifying it: `MKCALENDAR` is a `Dav.Web.Method`, and
  the queries are `Dav.Web.Report`s. That is the whole reason those
  seams exist, and why all three protocols live in one package without
  the base knowing what a calendar is.

      forward "/dav", to: Dav.Web.Plug,
        init_opts: [
          store: MyStore,
          methods: [{"MKCALENDAR", Dav.Cal.Mkcalendar}]
        ]

  """

  alias Dav.Cal.ICalendar
  alias Dav.Cal.JCal
  alias Dav.Cal.Selection
  alias Dav.Web.Properties
  alias Dav.Web.Resource
  alias Dav.Xml

  @doc """
  The resource type a calendar collection must report.

  RFC 4791 section 4.2: *"A calendar collection MUST report the
  DAV:collection and CALDAV:calendar XML elements in the value of the
  DAV:resourcetype property."* Setting this in a resource's `types`
  is what makes it a calendar as far as a client is concerned.

  ### Returns

  * The `CALDAV:calendar` qualified name.

  ### Examples

      iex> Dav.Cal.calendar()
      {"urn:ietf:params:xml:ns:caldav", "calendar"}

      iex> %Dav.Web.Resource{path: ["c"], collection?: true, types: [Dav.Cal.calendar()]}
      ...> |> Dav.Web.Properties.fetch({"DAV:", "resourcetype"})
      {:ok, {:names, [{"DAV:", "collection"}, {"urn:ietf:params:xml:ns:caldav", "calendar"}]}}

  """
  @spec calendar() :: Xml.qname()
  def calendar, do: {Xml.caldav(), "calendar"}

  @doc """
  Whether a value is a usable `CALDAV:calendar-timezone`.

  RFC 4791 section 5.2.2: the property "MUST contain a single
  VTIMEZONE component". A calendar carrying events as well is not a
  time zone definition, and a server that stored one would have to
  decide later which parts of it to ignore.

  ### Arguments

  * `value` is the property value as the client sent it.

  ### Returns

  * `true` when the value parses as iCalendar holding nothing but
    `VTIMEZONE` components, and `false` otherwise.

  ### Examples

      iex> Dav.Cal.timezone?("BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:UTC\r\nEND:VTIMEZONE\r\nEND:VCALENDAR\r\n")
      true

      iex> Dav.Cal.timezone?("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:1\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
      false

  """
  @spec timezone?(term()) :: boolean()
  def timezone?(value) when is_binary(value) do
    case ICalendar.parse(value) do
      {:ok, %{components: [_ | _] = components}} ->
        Enum.all?(components, &(&1.name == "VTIMEZONE"))

      _unreadable ->
        false
    end
  end

  def timezone?(_other), do: false

  @doc """
  Whether a value names a time zone this server knows.

  ### Arguments

  * `identifier` is a candidate time zone identifier, such as
    `"America/New_York"`.

  ### Returns

  * `true` when the identifier resolves in the zone database.

  ### Examples

      iex> Dav.Cal.timezone_id?("America/New_York")
      true

      iex> Dav.Cal.timezone_id?("bogus")
      false

  """
  @spec timezone_id?(term()) :: boolean()
  def timezone_id?(identifier) when is_binary(identifier) do
    match?({:ok, _now}, DateTime.now(identifier))
  rescue
    _no_database -> false
  end

  def timezone_id?(_other), do: false

  @doc """
  Whether a resource is a calendar collection.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports `CALDAV:calendar`.

  ### Examples

      iex> Dav.Cal.calendar?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.calendar?(%Dav.Web.Resource{collection?: true})
      false

  """
  @spec calendar?(Dav.Web.Resource.t()) :: boolean()
  def calendar?(%Dav.Web.Resource{types: types}), do: calendar() in types

  @doc """
  Build one resource's part of a `207 Multi-Status`.

  Shared by the reports, which differ in *which* objects they answer
  for and not in how they answer. `CALDAV:calendar-data` returns the
  object's own body — the point of both reports, since it saves a
  request per object.

  ### Arguments

  * `object` is the resolved `t:Dav.Web.Resource.t/0`.

  * `wanted` is the list of property names the client asked for.

  * `data` is the object's body, for `calendar-data`.

  ### Returns

  * A `{href, propstats}` pair for `Dav.Xml.multistatus/1`.

  ### Examples

      iex> object = %Dav.Web.Resource{path: ["c", "1.ics"], etag: ~s("v1")}
      iex> {href, [{status, _properties}]} = Dav.Cal.report_response(object, [{"DAV:", "getetag"}], "")
      iex> {href, status}
      {"/c/1.ics", "HTTP/1.1 200 OK"}

  """
  @spec report_response(Resource.t(), [Xml.qname()] | :allprop | :propname, binary()) ::
          {String.t(), [{String.t(), [{Xml.qname(), Xml.value()}]}]}
  # `DAV:allprop` and `DAV:propname` are as legal in a report as in a
  # PROPFIND, and a client sending one and receiving an empty propstat
  # has been told its resources have no properties.
  def report_response(%Resource{} = object, :allprop, _data) do
    {Resource.href(object), [{"HTTP/1.1 200 OK", Properties.all(object)}]}
  end

  def report_response(%Resource{} = object, :propname, _data) do
    names = for {name, _value} <- Properties.all(object), do: {name, nil}

    {Resource.href(object), [{"HTTP/1.1 200 OK", names}]}
  end

  def report_response(%Resource{} = object, wanted, data) do
    {found, missing} =
      Enum.reduce(wanted, {[], []}, fn name, {found, missing} ->
        case property(name, object, data) do
          {:ok, value} -> {found ++ [{name, value}], missing}
          :error -> {found, missing ++ [{name, nil}]}
        end
      end)

    propstats =
      [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(object), propstats}
  end

  defp property({namespace, "calendar-data"}, _object, data) do
    if namespace == Xml.caldav(), do: {:ok, data}, else: :error
  end

  defp property(name, object, _data), do: Properties.fetch(object, name)

  @doc """
  Build a response, returning only the part of the object asked for.

  As `report_response/3`, but honouring a `CALDAV:calendar-data`
  selection — see `Dav.Cal.Selection`.

  ### Arguments

  * `object` is the resolved `t:Dav.Web.Resource.t/0`.

  * `wanted` is the list of property names.

  * `data` is the object's body.

  * `selection` is a `t:Dav.Cal.Selection.t/0`.

  ### Returns

  * A `{href, propstats}` pair for `Dav.Xml.multistatus/1`.

  ### Examples

      iex> object = %Dav.Web.Resource{path: ["c", "1.ics"], etag: ~s("v1")}
      iex> {href, _propstats} = Dav.Cal.report_response(object, [], "", :everything)
      iex> href
      "/c/1.ics"

  """
  @spec report_response(
          Resource.t(),
          [Xml.qname()] | :allprop | :propname,
          binary(),
          Selection.t(),
          :icalendar | :jcal
        ) :: {String.t(), [{String.t(), [{Xml.qname(), Xml.value()}]}]}
  def report_response(%Resource{} = object, wanted, data, selection, syntax \\ :icalendar) do
    report_response(object, wanted, written_as(Selection.apply(data, selection), syntax))
  end

  # The selection decides *what* comes back and this decides how it is
  # written. A jCal answer says so in the element's `content-type`,
  # because a client reading the multistatus has no other way to tell
  # which of the two syntaxes it received.
  defp written_as(data, :icalendar), do: data

  defp written_as(data, :jcal) do
    case ICalendar.parse(data) do
      {:ok, component} -> {:typed, JCal.content_type(), JCal.encode(component)}
      _unreadable -> data
    end
  end
end
