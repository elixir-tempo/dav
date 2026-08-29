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

  @impl Dav.Web.Method
  def call(conn, path, %{store: store, context: context}) do
    {:ok, body, conn} = read_body(conn)

    with :ok <- supported(store),
         :ok <- empty(body),
         {:ok, _resource} <- store.mkcalendar(path, context) do
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

  defp empty(""), do: :ok
  defp empty(_body), do: {:error, :body}
end
