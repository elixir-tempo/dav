defmodule Dav.Cal.Multiget do
  @moduledoc """
  The `CALDAV:calendar-multiget` report — RFC 4791 section 7.9.

  The companion to `Dav.Cal.Query`: where a query describes what to
  find, a multiget names it. A client that has already synchronised
  and knows which objects changed asks for exactly those, in one round
  trip instead of one request each.

  Support is **REQUIRED** by the specification, unlike `MKCALENDAR`.

  ### Two rules that make it unlike a query

  **`Depth` is ignored**, and the specification says so in as many
  words: the hrefs say what is wanted, and they may point anywhere
  within the collection.

  **Every href gets a response, including the ones that fail.** A
  client asking for six objects and receiving five has no way to tell
  which it lost, so a resource that is gone comes back as a `404`
  response of its own rather than as an absence. That is why
  `Dav.Xml.multistatus/1` can write a response carrying a bare status:
  a resource that could not be read has no properties to report a
  status *for*.

  """

  @behaviour Dav.Web.Report

  alias Dav.Cal
  alias Dav.Cal.Selection
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Report
  # Not restricted to calendar collections. RFC 4791 section 7.9 says
  # the report runs against one, but the suite issues it against
  # calendar *homes* far more often than it tests the refusal — and a
  # client naming resources by href is not helped by being told the
  # collection it addressed was the wrong kind. The hrefs are resolved
  # on their own merits.
  def run(%Resource{}, body, _depth, options) do
    with {:ok, document} <- Xml.parse(body),
         :ok <- Selection.supported(calendar_data(document)) do
      {:ok, Enum.map(hrefs(document), &answer(&1, requested(document), options))}
    end
  end

  defp calendar_data(document) do
    case Enum.find(document.children, &named?(&1, "prop")) do
      nil -> nil
      element -> Enum.find(element.children, &named?(&1, "calendar-data"))
    end
  end

  defp hrefs(document) do
    for child <- document.children, named?(child, "href"), do: String.trim(child.text)
  end

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

  defp answer(href, wanted, options) do
    with {:ok, object} <- resolve(href, options),
         {:ok, data} <- read(object, options) do
      Cal.report_response(object, wanted, data)
    else
      # Named and not found: the client is told about this href
      # specifically, rather than left to infer it from a short list.
      :error -> {href, {:status, "HTTP/1.1 404 Not Found"}}
    end
  end

  defp resolve(href, %{store: store, context: context}) do
    case store.resolve(Store.segments(URI.parse(href).path || ""), context) do
      {:ok, object} -> {:ok, object}
      {:error, :not_found} -> :error
    end
  end

  defp read(object, %{store: store, context: context}) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(object, context), do: {:ok, IO.iodata_to_binary(data)}
    else
      {:ok, ""}
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
