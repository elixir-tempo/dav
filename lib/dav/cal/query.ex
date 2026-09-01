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
  alias Dav.Cal.Expand
  alias Dav.Cal.Filter
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Selection
  alias Dav.Cal.TimeRange
  alias Dav.Web.Hook
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
    with :ok <- addressable(target, options),
         {:ok, document} <- Xml.parse(body),
         :ok <- Selection.supported(calendar_data(document)),
         :ok <- timezone_of(document),
         {:ok, filter} <- filter_of(document) do
      {:ok, matching(target, filter, depth, document, options)}
    end
  end

  # RFC 4791 section 7.8: the report is made against a calendar
  # collection or a calendar object resource. A file that merely ends
  # in `.ics`, sitting in an ordinary collection, is neither — and
  # answering for it would report as calendar data something the
  # server treats as calendar data nowhere else. A collection is
  # allowed through: a query against a plain one finds nothing, which
  # is the right answer to "is there anything here".
  defp addressable(%Resource{collection?: true}, _options), do: :ok

  defp addressable(%Resource{path: path}, %{store: store, context: context}) do
    with {:ok, parent} <- store.resolve(Enum.drop(path, -1), context),
         true <- Cal.calendar?(parent) do
      :ok
    else
      _not_held_in_a_calendar -> {:error, {Xml.caldav(), "supported-calendar-data"}}
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
         :ok <- bounded(filter),
         :ok <- Filter.valid?(filter) do
      {:ok, filter}
    else
      {:error, :unbounded} -> {:error, :malformed}
      _not_a_filter -> {:error, {Xml.caldav(), "valid-filter"}}
    end
  end

  # RFC 4791 section 9.9: `CALDAV:time-range` carries `start`, `end`,
  # or both. With neither it states no range at all, which is a
  # malformed element rather than a filter the server declines to
  # run — so it is `400`, not `CALDAV:valid-filter`.
  defp bounded(%Filter{} = filter) do
    if filter.time_range == {nil, nil} or Enum.any?(filter.children, &(bounded(&1) != :ok)) do
      {:error, :unbounded}
    else
      :ok
    end
  end

  # RFC 4791 section 9.1: `CALDAV:timezone` "MUST contain a single
  # VTIMEZONE component". A calendar carrying events as well is not a
  # time zone definition — the server would have to decide which parts
  # to ignore, and a client that meant to send a whole calendar needs
  # to hear that rather than have most of it dropped.
  defp timezone_of(document) do
    case Enum.find(document.children, &named?(&1, "timezone")) do
      nil -> timezone_id_of(document)
      element -> only_zones(element.text)
    end
  end

  # RFC 7809 section 5.2: `CALDAV:timezone-id` names a zone by
  # identifier instead of shipping the definition, and an identifier
  # the server does not know fails `CALDAV:valid-timezone`.
  defp timezone_id_of(document) do
    case Enum.find(document.children, &named?(&1, "timezone-id")) do
      nil ->
        :ok

      element ->
        if Cal.timezone_id?(String.trim(element.text)),
          do: :ok,
          else: {:error, {Xml.caldav(), "valid-timezone"}}
    end
  end

  defp only_zones(text) do
    if Cal.timezone?(text), do: :ok, else: {:error, {Xml.caldav(), "valid-calendar-data"}}
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
    expand = Expand.from_element(calendar_data(document))
    floating = floating_zone(document, target, options)

    for object <- scope(target, depth, options),
        {:ok, data} <- [read(object, options)],
        {:ok, calendar} <- [ICalendar.parse(data)],
        Filter.match?(filter, calendar, time_range: ranged(floating), calendar: calendar),
        do: Cal.report_response(object, wanted, Expand.apply(data, expand, floating), selection)
  end

  # A `VALARM` has no time of its own — it fires relative to whatever
  # holds it — so the parent is needed to answer a `time-range` about
  # it. Every other component answers for itself.
  defp ranged(floating) do
    fn target, range, context ->
      case {target, Keyword.get(context, :parent)} do
        {%{name: "VALARM"}, nil} ->
          false

        {%{name: "VALARM"} = alarm, parent} ->
          TimeRange.alarm_overlaps?(alarm, parent, range, floating, siblings(parent, context))

        {component, parent} ->
          TimeRange.overlaps?(component, range, floating, kin(component, parent))
      end
    end
  end

  # The other components of the same calendar object describing the
  # same event. A `RANGE=THISANDFUTURE` override changes where the
  # master's later occurrences fall, so the master cannot be tested
  # against a window without them.
  # An alarm's parent is the component it hangs off, so its siblings
  # are found from the calendar rather than from the parent — which by
  # then is the event, not the object.
  defp siblings(parent, context), do: kin(parent, Keyword.get(context, :calendar))

  defp kin(_component, nil), do: []

  defp kin(component, parent) do
    Enum.reject(parent.components, &(&1 == component or &1.name != component.name))
  end

  # RFC 4791 section 3.1: a floating time is converted using the
  # request's `CALDAV:timezone` if it carries one, otherwise the
  # collection's `CALDAV:calendar-timezone`. Without this every
  # floating event is read as UTC, which moves it by the collection's
  # offset — hours, easily enough to fall outside the window asked for.
  defp floating_zone(document, target, options) do
    named_zone =
      case Enum.find(document.children, &named?(&1, "timezone")) do
        nil ->
          # RFC 7809 section 4: `CALDAV:timezone-id` names the zone by
          # identifier instead of shipping the whole VTIMEZONE.
          case Enum.find(document.children, &named?(&1, "timezone-id")) do
            nil -> nil
            element -> element.text
          end

        element ->
          tzid(element.text)
      end

    named_zone || collection_zone(target, options)
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
    {collections, _objects} = split(collection, options)

    objects(collection, options) ++ Enum.flat_map(collections, &objects(&1, options))
  end

  defp scope(collection, :infinity, options) do
    {collections, _objects} = split(collection, options)

    objects(collection, options) ++ Enum.flat_map(collections, &scope(&1, :infinity, options))
  end

  # Only a calendar collection holds calendar object resources. A
  # plain collection may have `.ics` files in it, but they are files —
  # reporting them would answer a calendar query with resources the
  # server does not treat as calendar data anywhere else. A scheduling
  # Inbox counts: RFC 6638 section 2.2 makes it a calendar collection
  # of its own kind, and a client reads it with the same reports.
  defp objects(collection, options) do
    if calendared?(collection), do: collection |> split(options) |> elem(1), else: []
  end

  defp calendared?(%Resource{types: types}) do
    Enum.any?(types, &match?({unquote(Xml.caldav()), _local}, &1))
  end

  defp split(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.split_with(children, & &1.collection?)
      _nothing -> {[], []}
    end
  end

  defp read(object, %{store: store, context: context} = options) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(object, context),
           do: Hook.disclosure(object, IO.iodata_to_binary(data), options)
    else
      :error
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
