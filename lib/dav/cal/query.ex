defmodule Dav.Cal.Query do
  @moduledoc """
  The `CALDAV:calendar-query` report — RFC 4791 section 7.8.

  The report a client uses to ask *"what is in my calendar between
  these two dates"*, and the reason CalDAV exists rather than clients
  fetching every object and sorting it out themselves.

      <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:prop>
          <D:getetag/>
          <C:calendar-data/>
        </D:prop>
        <C:filter>
          <C:comp-filter name="VCALENDAR">
            <C:comp-filter name="VEVENT">
              <C:time-range start="20260601T000000Z" end="20260701T000000Z"/>
            </C:comp-filter>
          </C:comp-filter>
        </C:filter>
      </C:calendar-query>

  Register it with `Dav.Web.Plug`, which then advertises it through
  `DAV:supported-report-set` so clients discover it rather than
  guessing:

      forward "/dav", to: Dav.Web.Plug,
        init_opts: [
          store: MyStore,
          reports: [{{Dav.Xml.caldav(), "calendar-query"}, Dav.Cal.Query}]
        ]

  ### What it needs of a store

  `c:Dav.Web.Store.read/2`, because matching means looking at the
  calendar data. A store that cannot read bodies cannot answer this
  report, and says so with an empty result rather than an error —
  there is nothing wrong with the request.

  """

  @behaviour Dav.Web.Report

  alias Dav.Cal
  alias Dav.Cal.Filter
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Selection
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Report
  # A query on an ordinary collection is answered, not refused. It
  # searches the calendars beneath it and finds nothing of its own,
  # which is what a client asking "is there anything here" means — and
  # what the conformance suite expects. Refusing it would also make a
  # calendar home unqueryable, since a home is a plain collection.
  def run(%Resource{} = target, body, depth, options) do
    with {:ok, document} <- Xml.parse(body),
         :ok <- Selection.supported(calendar_data(document)),
         {:ok, filter} <- filter_of(document) do
      {:ok, matching(target, filter, depth, document, options)}
    end
  end

  # RFC 4791 section 7.8 gives this its own precondition. A filter that
  # names a component that cannot be there, or nests in a way the
  # grammar does not allow, is a client mistake with a specific name —
  # `CALDAV:valid-filter` — and answering `207` with an empty result
  # instead tells the client its calendar is empty.
  defp filter_of(document) do
    with element when not is_nil(element) <- Enum.find(document.children, &named?(&1, "filter")),
         {:ok, filter} <- Filter.from_element(element),
         :ok <- rooted(filter),
         :ok <- Filter.valid?(filter) do
      {:ok, filter}
    else
      _not_a_filter -> {:error, {Xml.caldav(), "valid-filter"}}
    end
  end

  # "The CALDAV:filter element... MUST contain a single CALDAV:comp-
  # filter element naming VCALENDAR." Anything else describes no
  # calendar data at all.
  defp rooted(%Filter{name: "VCALENDAR"}), do: :ok
  defp rooted(_other), do: :error

  # The properties asked for. An absent `DAV:prop` means the client
  # wants only the hrefs, which is a legitimate and cheap request.
  # A report may ask for named properties, or for all of them, or for
  # their names alone — the same three forms PROPFIND offers.
  defp requested(document) do
    cond do
      Enum.any?(document.children, &named?(&1, "allprop")) -> :allprop
      Enum.any?(document.children, &named?(&1, "propname")) -> :propname
      true -> named_properties(document)
    end
  end

  defp named_properties(document) do
    case Enum.find(document.children, &named?(&1, "prop")) do
      nil -> []
      element -> for child <- element.children, do: child.name
    end
  end

  defp matching(target, filter, depth, document, options) do
    wanted = requested(document)
    selection = Selection.from_element(calendar_data(document))
    floating = floating_zone(document, target, options)

    for object <- scope(target, depth, options),
        {:ok, data} <- [read(object, options)],
        {:ok, calendar} <- [ICalendar.parse(data)],
        Filter.match?(filter, calendar, time_range: &TimeRange.overlaps?(&1, &2, floating)),
        do: Cal.report_response(object, wanted, data, selection)
  end

  # RFC 4791 section 3.1: a floating time is converted using the
  # request's `CALDAV:timezone` if it carries one, otherwise the
  # collection's `CALDAV:calendar-timezone`. Without this every
  # floating event is read as UTC, which moves it by the collection's
  # offset — hours, easily enough to fall outside the window asked for.
  defp floating_zone(document, target, options) do
    case Enum.find(document.children, &named?(&1, "timezone")) do
      nil -> collection_zone(target, options)
      element -> tzid(element.text) || collection_zone(target, options)
    end
  end

  defp collection_zone(target, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(target, context),
         value when is_binary(value) <-
           Map.get(properties, {Xml.caldav(), "calendar-timezone"}) do
      tzid(value)
    else
      _absent -> nil
    end
  end

  # The property holds a whole VTIMEZONE; the zone is its TZID.
  defp tzid(text) when is_binary(text) do
    case Regex.run(~r/^TZID:(.+)$/m, text) do
      [_line, zone] -> String.trim(zone)
      _absent -> nil
    end
  end

  defp tzid(_absent), do: nil

  # The `calendar-data` element does double duty: naming it asks for
  # the object, and its children say how much of it.
  defp calendar_data(document) do
    case Enum.find(document.children, &named?(&1, "prop")) do
      nil -> nil
      element -> Enum.find(element.children, &named?(&1, "calendar-data"))
    end
  end

  # Depth bounds how far the search *descends*, not whether the target
  # itself is searched. A calendar collection's own objects are always
  # in scope — a `Depth: 0` query on a calendar asks about that
  # calendar, and answering "nothing" because a collection is not
  # itself a calendar object would be a pedantic reading of a request
  # whose meaning is obvious. `1` adds the objects of its child
  # collections, and `infinity` keeps going.
  defp scope(%Resource{collection?: false} = object, _depth, _options), do: [object]

  # `0` is the collection's own calendar objects — a calendar's members
  # are the objects themselves, so a Depth 0 query on one finds them,
  # while an ordinary collection holds further collections and
  # correctly finds nothing.
  defp scope(collection, 0, options), do: objects(collection, options)

  # `1` adds the objects of the immediate child collections, which is
  # what makes a query against a calendar *home* useful.
  defp scope(collection, 1, options) do
    {collections, objects} = split(collection, options)

    objects ++ Enum.flat_map(collections, &objects(&1, options))
  end

  defp scope(collection, :infinity, options) do
    {collections, objects} = split(collection, options)

    objects ++ Enum.flat_map(collections, &scope(&1, :infinity, options))
  end

  defp objects(collection, options), do: collection |> split(options) |> elem(1)

  defp split(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.split_with(children, & &1.collection?)
      _nothing -> {[], []}
    end
  end

  defp read(object, %{store: store, context: context}) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(object, context), do: {:ok, IO.iodata_to_binary(data)}
    else
      :error
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
