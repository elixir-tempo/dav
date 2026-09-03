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

  The one place the target settles it is iCalendar, because the same
  body means two things. `POST`ed at an Outbox it is a scheduling
  message; `POST`ed at a calendar collection it is Apple's bulk
  request, asking for the components in it to be stored. Nothing in
  the body distinguishes them, so that one case asks where it was
  sent.

  """

  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.Bulk
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
    handler(body, path, options).call(conn, path, Map.put(options, :body, body))
  end

  # A `POST` is a sharing request when its body is one, a bulk request
  # when its body is an `MM:multiput`, and scheduling otherwise.
  # Routing on the body's first character instead sends every XML body
  # to the sharing handler — including a client's mis-typed scheduling
  # `POST`, which then hears "not a sharing document" rather than the
  # scheduling precondition that says what it actually got wrong.
  @namespace "http://calendarserver.org/ns/"
  @sharing ~w(share invite-reply)

  defp handler(body, path, options) do
    cond do
      String.starts_with?(String.trim_leading(body), "<") -> documented(body)
      calendar?(path, options) -> Bulk
      true -> Outbox
    end
  end

  defp documented(body) do
    case Xml.parse(body) do
      {:ok, %{name: {@namespace, local}}} when local in @sharing -> Sharing
      {:ok, %{name: name}} -> if name == Bulk.multiput(), do: Bulk, else: Outbox
      _not_a_document -> Outbox
    end
  end

  defp calendar?(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, resource} -> Cal.calendar?(resource)
      _absent -> false
    end
  end
end
