defmodule Dav.Cal.Mkcalendar do
  @moduledoc """
  `MKCALENDAR` — RFC 4791 section 5.3.1.

  Creates a calendar collection: an ordinary collection that reports
  `CALDAV:calendar` in its resource type. Registered as a
  `Dav.Web.Method`, so the base protocol never learns what a calendar
  is.

  Support is only RECOMMENDED by the specification, because some
  calendar stores pre-create one calendar per principal and never make
  more. A store that does not implement `c:Dav.Web.Store.mkcalendar/2`
  therefore gets a server that does not advertise the method, rather
  than one that fails when it is used.

  ### The request body

  A body may carry properties to set on the new calendar. That is not
  implemented: a body is refused with `415` rather than silently
  ignored, because a client that set `DAV:displayname` at creation and
  had it dropped would show the user an unnamed calendar. RFC 4791
  anticipates this — it tells clients they may instead `PROPPATCH`
  immediately afterwards.

  """

  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.Sharing
  alias Dav.Web.Hook
  alias Dav.Web.Properties
  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Method
  def call(conn, path, %{store: store, context: context} = options) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- supported(store),
         {:ok, properties} <- requested(body),
         :ok <- Hook.creation(path, :calendar, options),
         :ok <- vacant(path, options),
         :ok <- unretired(path, options),
         :ok <- settable(properties),
         :ok <- outside_calendars(path, options),
         {:ok, resource} <- store.mkcalendar(path, context) do
      apply_properties(resource, properties, options)
      send_resp(conn, 201, "")
    else
      {:error, :unsupported} ->
        send_resp(conn, 405, "")

      {:error, :retired} ->
        send_resp(conn, 403, "")

      {:error, :method_not_allowed} ->
        send_resp(conn, 405, "")

      {:error, :body} ->
        send_resp(conn, 415, "")

      # A calendar may not be created where something already is, and
      # MUST NOT be created inside another calendar.
      # RFC 4918's `DAV:resource-must-be-null` — a bare 405 says the
      # method was refused, this says the URL was already taken.
      {:error, :exists} ->
        precondition(conn, {Xml.dav(), "resource-must-be-null"})

      {:error, :inside_calendar} ->
        precondition(conn, {Xml.caldav(), "calendar-collection-location-ok"})

      # RFC 4791 section 5.3.1.2: a body asking for a property the
      # client may not set fails the whole request as a `207`, naming
      # the property that refused and marking the rest as never
      # attempted — and the calendar is not created.
      {:error, {:unsettable, properties}} ->
        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(207, Xml.multistatus([refused(path, properties)]))

      {:error, :conflict} ->
        send_resp(conn, 409, "")

      {:error, :forbidden} ->
        send_resp(conn, 403, "")
    end
  end

  # The URL being taken outranks any complaint about the body: a 207
  # about properties on a calendar that cannot be created reads as
  # though it could have been.
  # A sharee who deleted their view of a shared calendar has left the
  # share, and the path stays spoken for — the share can come back,
  # and a plain calendar sitting in its place could not be told apart
  # from it.
  defp unretired(path, options) do
    if Sharing.retired?(path, options), do: {:error, :retired}, else: :ok
  end

  defp vacant(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, _resource} -> {:error, :exists}
      _absent -> :ok
    end
  end

  defp settable(properties) do
    if Enum.any?(properties, fn {name, _value} -> Properties.protected?(name) end),
      do: {:error, {:unsettable, properties}},
      else: :ok
  end

  defp refused(path, properties) do
    {denied, blocked} =
      Enum.split_with(properties, fn {name, _value} -> Properties.protected?(name) end)

    propstats =
      [
        {"HTTP/1.1 403 Forbidden", for({name, _value} <- denied, do: {name, nil})},
        {"HTTP/1.1 424 Failed Dependency", for({name, _value} <- blocked, do: {name, nil})}
      ]
      |> Enum.reject(fn {_status, listed} -> listed == [] end)

    {"/" <> Enum.join(path, "/") <> "/", propstats}
  end

  defp outside_calendars(path, %{store: store, context: context}) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, parent} -> if Cal.calendar?(parent), do: {:error, :inside_calendar}, else: :ok
      _absent -> :ok
    end
  end

  defp precondition(conn, condition) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error(condition))
  end

  defp supported(store) do
    if Store.supports?(store, :mkcalendar), do: :ok, else: {:error, :unsupported}
  end

  # "Clients can either specify the value of the DAV:displayname
  # property in the request body of the MKCALENDAR request, or
  # alternatively issue a PROPPATCH" — so a body is not merely
  # tolerated, it is the documented way to name a calendar as it is
  # created. Refusing it forced every client into a second round trip
  # and failed the one form the specification shows.
  defp requested(""), do: {:ok, []}

  defp requested(body) do
    case Xml.parse(body) do
      {:ok, %{name: {_namespace, "mkcalendar"}} = document} -> {:ok, properties(document)}
      _not_a_mkcalendar_body -> {:error, :body}
    end
  end

  # The body has the shape of a PROPPATCH: `DAV:set` holding a
  # `DAV:prop` of the properties to give the new collection.
  defp properties(document) do
    for set <- children(document, "set"),
        prop <- children(set, "prop"),
        property <- prop.children,
        do: {property.name, value(property)}
  end

  defp value(%{children: [], text: text}), do: String.trim(text)

  # `CALDAV:comp` names its component in an attribute, so keeping only
  # the element names would record "some components, unspecified" — and
  # a calendar created for events alone would go on accepting to-dos.
  defp value(%{children: children}) do
    case Enum.map(children, &Map.get(&1.attributes, "name")) do
      [_ | _] = named -> componentwise(children, named)
      [] -> {:names, []}
    end
  end

  defp componentwise(children, named) do
    if Enum.all?(named, &is_binary/1),
      do: {:components, named},
      else: {:names, Enum.map(children, & &1.name)}
  end

  defp children(element, name) do
    Enum.filter(element.children, &match?(%{name: {_namespace, ^name}}, &1))
  end

  # Properties are best-effort: RFC 4791 lets a server reject the whole
  # request if it cannot set them, but a store with no `patch/3` can
  # still make the calendar, and a nameless calendar is more useful
  # than none.
  defp apply_properties(_resource, [], _options), do: :ok

  defp apply_properties(resource, properties, %{store: store, context: context}) do
    if Store.supports?(store, :patch) do
      store.patch(
        resource,
        Enum.map(properties, fn {name, value} -> {:set, name, value} end),
        context
      )
    end

    :ok
  end
end
