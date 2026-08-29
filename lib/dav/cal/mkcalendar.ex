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

  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Method
  def call(conn, path, %{store: store, context: context} = options) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- supported(store),
         {:ok, properties} <- requested(body),
         {:ok, resource} <- store.mkcalendar(path, context) do
      apply_properties(resource, properties, options)
      send_resp(conn, 201, "")
    else
      {:error, :unsupported} -> send_resp(conn, 405, "")
      {:error, :body} -> send_resp(conn, 415, "")
      # A calendar may not be created where something already is, and
      # MUST NOT be created inside another calendar.
      {:error, :exists} -> send_resp(conn, 405, "")
      {:error, :conflict} -> send_resp(conn, 409, "")
      {:error, :forbidden} -> send_resp(conn, 403, "")
    end
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
  defp value(%{children: children}), do: {:names, Enum.map(children, & &1.name)}

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
