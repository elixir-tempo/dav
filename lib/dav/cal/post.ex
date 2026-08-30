defmodule Dav.Cal.Post do
  @moduledoc """
  `POST` on a calendar resource, routed by what the body is.

  `POST` is the one method CalDAV overloads. A scheduling message and
  a sharing invitation arrive by the same method at different URLs,
  and the only reliable way to tell them apart is to look at the body:
  iCalendar is a scheduling message for an Outbox, and a
  `CS:share` or `CS:invite-reply` document is Apple's sharing
  extension.

  Dispatching on the target resource's type instead would be wrong —
  a sharing invitation is `POST`ed *at the calendar being shared*, and
  a scheduling message at an Outbox, but the reply to a sharing
  invitation goes to the invitee's calendar home, which is neither.

  """

  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal.Outbox
  alias Dav.Cal.Sharing
  alias Dav.Xml

  @impl Dav.Web.Method
  def call(conn, path, options) do
    {:ok, body, conn} = read_body(conn)

    # The body travels in the options rather than being pushed back
    # into the connection. Rewinding means reaching into the adapter's
    # private state, which differs between `Plug.Test` and Bandit —
    # this works the same under both.
    handler(body).call(conn, path, Map.put(options, :body, body))
  end

  # A `POST` is a sharing request when its body is one, and scheduling
  # otherwise. Routing on the body's first character instead sends
  # every XML body to the sharing handler — including a client's
  # mis-typed scheduling `POST`, which then hears "not a sharing
  # document" rather than the scheduling precondition that says what
  # it actually got wrong.
  @namespace "http://calendarserver.org/ns/"
  @sharing ~w(share invite-reply)

  defp handler(body) do
    with true <- String.starts_with?(String.trim_leading(body), "<"),
         {:ok, %{name: {@namespace, local}}} <- Xml.parse(body),
         true <- local in @sharing do
      Sharing
    else
      _not_a_sharing_document -> Outbox
    end
  end
end
