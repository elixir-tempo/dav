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
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Report
  def run(%Resource{} = collection, body, _depth, options) do
    with {:ok, document} <- Xml.parse(body),
         {:ok, filter} <- filter_of(document) do
      {:ok, matching(collection, filter, requested(document), options)}
    end
  end

  defp filter_of(document) do
    case Enum.find(document.children, &named?(&1, "filter")) do
      nil -> {:error, :malformed}
      element -> Filter.from_element(element)
    end
  end

  # The properties asked for. An absent `DAV:prop` means the client
  # wants only the hrefs, which is a legitimate and cheap request.
  defp requested(document) do
    case Enum.find(document.children, &named?(&1, "prop")) do
      nil -> []
      element -> for child <- element.children, do: child.name
    end
  end

  defp matching(collection, filter, wanted, options) do
    for object <- members(collection, options),
        {:ok, data} <- [read(object, options)],
        {:ok, calendar} <- [ICalendar.parse(data)],
        Filter.match?(filter, calendar, time_range: &TimeRange.overlaps?/2),
        do: Cal.report_response(object, wanted, data)
  end

  defp members(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.reject(children, & &1.collection?)
      _nothing -> []
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
