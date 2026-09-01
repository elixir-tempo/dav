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
  alias Dav.Web.Hook
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
  def run(%Resource{} = target, body, _depth, options) do
    with {:ok, document} <- Xml.parse(body),
         :ok <- Selection.supported(calendar_data(document)),
         :ok <- addressable(target, options) do
      selection = Selection.from_element(calendar_data(document))

      {:ok,
       Enum.map(hrefs(document), &answer(&1, target, requested(document), selection, options))}
    end
  end

  # RFC 4791 section 7.9: the report is made against a calendar
  # collection or a calendar object resource. A file in an ordinary
  # collection is neither, and answering for it would report as
  # calendar data something the server treats as calendar data
  # nowhere else.
  defp addressable(%Resource{collection?: true}, _options), do: :ok

  defp addressable(%Resource{} = target, %{store: store, context: context}) do
    if held_in_calendar?(target, store, context),
      do: :ok,
      else: {:error, {Xml.caldav(), "supported-calendar-data"}}
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

  defp answer(href, target, wanted, selection, options) do
    with {:ok, object} <- resolve(href, target, options),
         {:ok, data} <- read(object, options) do
      Cal.report_response(object, wanted, data, selection)
    else
      # Named and not found: the client is told about this href
      # specifically, rather than left to infer it from a short list.
      :error -> {href, {:status, "HTTP/1.1 404 Not Found"}}
      # Named and withheld: a private event another user asked for by
      # name is refused for that name alone, not dropped silently.
      {:error, :forbidden} -> {href, {:status, "HTTP/1.1 403 Forbidden"}}
    end
  end

  # An href in a request body is escaped once as XML content and once
  # as a URI, so it carries one more layer than a request line does:
  # `3%2520a.ics` here names the resource `3 a.ics`.
  defp resolve(href, target, %{store: store, context: context}) do
    segments = Enum.map(Store.segments(URI.parse(href).path || ""), &URI.decode/1)

    case store.resolve(segments, context) do
      {:ok, object} ->
        if addressed?(object, target) and held_in_calendar?(object, store, context),
          do: {:ok, object},
          else: :error

      {:error, :not_found} ->
        :error
    end
  end

  # A report made against one resource answers for that resource. The
  # hrefs a client sends name members of a collection; against a
  # single object there is one member, and any other name is asking
  # about somebody else's resource.
  defp addressed?(_object, %Resource{collection?: true}), do: true
  defp addressed?(%Resource{path: path}, %Resource{path: path}), do: true
  defp addressed?(_object, _target), do: false

  # A calendar object resource lives in a calendar collection. An
  # `.ics` file in an ordinary collection is a file, and answering for
  # it would report as calendar data something the server treats as
  # calendar data nowhere else.
  defp held_in_calendar?(%Resource{collection?: true}, _store, _context), do: true

  defp held_in_calendar?(%Resource{path: path}, store, context) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, collection} -> Cal.calendar?(collection)
      _no_parent -> false
    end
  end

  defp read(object, %{store: store, context: context} = options) do
    if Store.supports?(store, :read) do
      with {:ok, data} <- store.read(object, context),
           do: Hook.disclosure(object, IO.iodata_to_binary(data), options)
    else
      {:ok, ""}
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
