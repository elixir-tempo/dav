defmodule Dav.Cal.Sharing do
  @moduledoc """
  Calendar sharing — Apple's `calendarserver.org` extension.

  Letting one person see or edit another's calendar, which every
  CalDAV client on Apple's platforms expects and which no RFC defines.
  It is a vendor extension, and it is the one most widely deployed:
  ignoring it means a server that Apple Calendar can talk to but not
  share with.

  ### How a share is made

  The owner `POST`s a `CS:share` document at their calendar, naming
  who to invite and what access to grant:

      <CS:share xmlns:D="DAV:" xmlns:CS="http://calendarserver.org/ns/">
        <CS:set>
          <D:href>mailto:bob@example.com</D:href>
          <CS:summary>My Shared Calendar</CS:summary>
          <CS:read-write/>
        </CS:set>
      </CS:share>

  The server records the invitation on the calendar — reported by the
  `CS:invite` property — and drops a **notification** into the
  invitee's notification collection. The invitee replies by `POST`ing
  a `CS:invite-reply`, and on acceptance the server answers with the
  URL the shared calendar now has in *their* home.

  ### Why the notification matters

  There is nowhere else for the invitation to go. An invitee has no
  reason to poll a calendar they cannot yet see, so a share that is
  recorded only on the owner's side is a share nobody hears about.

  """

  @behaviour Dav.Web.Hook
  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @namespace "http://calendarserver.org/ns/"

  @doc """
  The `calendarserver.org` namespace.

  ### Returns

  * The namespace URI.

  ### Examples

      iex> Dav.Cal.Sharing.namespace()
      "http://calendarserver.org/ns/"

  """
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The resource type of a notification collection.

  ### Returns

  * The `CS:notification` qualified name.

  ### Examples

      iex> Dav.Cal.Sharing.notification()
      {"http://calendarserver.org/ns/", "notification"}

  """
  @spec notification() :: Xml.qname()
  def notification, do: {@namespace, "notification"}

  @doc """
  The resource type a shared calendar reports alongside `calendar`.

  ### Returns

  * The `CS:shared-owner` qualified name.

  ### Examples

      iex> Dav.Cal.Sharing.shared_owner()
      {"http://calendarserver.org/ns/", "shared-owner"}

  """
  @spec shared_owner() :: Xml.qname()
  def shared_owner, do: {@namespace, "shared-owner"}

  @doc """
  Whether the sharing properties apply — only to a calendar.

  ### Arguments

  * `collection` is the resource being described.

  ### Returns

  * `true` for a calendar collection.

  ### Examples

      iex> Dav.Cal.Sharing.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  Sharing has nothing to do when a calendar object is written.

  ### Arguments

  * `change` is the write, ignored.

  * `options` is ignored.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  The sharing properties of a calendar.

  `CS:invite` lists who has been invited and what they were granted —
  it is how an owner's client shows the sharing panel — and
  `CS:allowed-sharing-modes` says whether the calendar may be shared
  at all.

  ### Arguments

  * `resource` is the calendar.

  * `collection` is its parent, unused.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The sharing properties.

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(resource, _collection, options) do
    if Cal.calendar?(resource) do
      [
        {{@namespace, "invite"}, invite(resource, options)},
        {{@namespace, "allowed-sharing-modes"}, {:elements, [@namespace], "<CS:can-be-shared/>"}}
      ]
    else
      []
    end
  end

  defp invite(calendar, %{store: store, context: context}) do
    inner =
      for invitation <- current(calendar, store, context) do
        [
          "<CS:user>",
          "<D:href>",
          escape(invitation.href),
          "</D:href>",
          "<CS:invite-noresponse/>",
          "<CS:access><CS:",
          invitation.access,
          "/></CS:access>",
          "<CS:summary>",
          escape(invitation.summary || ""),
          "</CS:summary>",
          "</CS:user>"
        ]
      end

    {:elements, [@namespace, Xml.dav()], inner}
  end

  @impl Dav.Web.Method
  def call(conn, path, options) do
    with {:ok, resource} <- resolve(path, options),
         {:ok, body, conn} <- request_body(conn, options),
         {:ok, document} <- Xml.parse(body) do
      dispatch(conn, document, resource, options)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      _unreadable -> send_resp(conn, 400, "")
    end
  end

  defp dispatch(conn, %{name: {@namespace, "share"}} = document, resource, options) do
    if Cal.calendar?(resource) do
      share(conn, document, resource, options)
    else
      send_resp(conn, 403, "")
    end
  end

  defp dispatch(conn, %{name: {@namespace, "invite-reply"}} = document, resource, options) do
    reply(conn, document, resource, options)
  end

  # Not a sharing document. Another `POST` handler may want it, and
  # saying so is more useful than refusing on its behalf.
  defp dispatch(conn, _document, _resource, _options), do: send_resp(conn, 400, "")

  ## --- inviting ---------------------------------------------------

  defp share(conn, document, calendar, options) do
    invitations = for element <- children(document, "set"), do: invitation(element)
    removals = for element <- children(document, "remove"), do: href_of(element)

    record(calendar, invitations, removals, options)
    for invitation <- invitations, do: notify(calendar, invitation, options)

    send_resp(conn, 200, "")
  end

  defp invitation(element) do
    %{
      href: href_of(element),
      summary: text_of(element, "summary"),
      access: access_of(element)
    }
  end

  # `CS:read` or `CS:read-write`; read is the safer default when
  # neither is named, since granting write by accident is the mistake
  # that cannot be undone.
  defp access_of(element) do
    if Enum.any?(element.children, &named?(&1, "read-write")), do: "read-write", else: "read"
  end

  # The invitations live on the calendar as a dead property, which is
  # where `CS:invite` reads them from.
  defp record(calendar, invitations, removals, %{store: store, context: context}) do
    if Store.supports?(store, :patch) do
      existing = current(calendar, store, context)

      # A re-invitation replaces the earlier one rather than sitting
      # beside it, so anyone named in this request is dropped first.
      replaced = removals ++ Enum.map(invitations, & &1.href)
      kept = Enum.reject(existing, &(&1.href in replaced))

      store.patch(calendar, [{:set, invite_property(), encode(kept ++ invitations)}], context)
    end

    :ok
  end

  defp current(calendar, store, context) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(calendar, context),
         value when is_binary(value) <- Map.get(properties, invite_property()) do
      decode(value)
    else
      _none -> []
    end
  end

  defp invite_property, do: {@namespace, "invite-state"}

  # Stored as text rather than as XML: the property is this server's
  # own bookkeeping, and a store that can hold a string can hold it.
  defp encode(invitations) do
    Enum.map_join(invitations, "\n", &"#{&1.href}\t#{&1.access}\t#{&1.summary}")
  end

  defp decode(value) do
    for line <- String.split(value, "\n", trim: true),
        [href, access, summary] <- [String.split(line, "\t", parts: 3)],
        do: %{href: href, access: access, summary: summary}
  end

  ## --- notifying --------------------------------------------------

  # The invitee has no reason to poll a calendar they cannot see yet,
  # so the invitation is delivered to their notification collection.
  defp notify(calendar, invitation, options) do
    with %Resource{} = collection <- notifications_of(invitation.href, options),
         %{store: store, context: context} <- options,
         true <- Store.supports?(store, :put) do
      uid = uid_for(calendar, invitation)

      store.put(
        collection.path ++ [uid <> ".xml"],
        invite_notification(calendar, invitation, uid),
        "text/xml",
        context
      )
    end

    :ok
  end

  defp uid_for(calendar, invitation) do
    :crypto.hash(:sha, Resource.href(calendar) <> invitation.href) |> Base.encode16(case: :lower)
  end

  defp notifications_of(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context),
         {:ok, children} <- store.children(home, context) do
      Enum.find(children, &(notification() in &1.types))
    else
      _unknown -> nil
    end
  end

  defp invite_notification(calendar, invitation, uid) do
    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      ~s(<CS:notification xmlns:D="DAV:" xmlns:CS="),
      @namespace,
      ~s(">),
      "<CS:dtstamp>",
      stamp(),
      "</CS:dtstamp>",
      ~s(<CS:invite-notification shared-type="calendar">),
      "<CS:uid>",
      uid,
      "</CS:uid>",
      "<D:href>",
      escape(invitation.href),
      "</D:href>",
      "<CS:invite-noresponse/>",
      "<CS:access><CS:",
      invitation.access,
      "/></CS:access>",
      "<CS:hosturl><D:href>",
      escape(Resource.href(calendar)),
      "</D:href></CS:hosturl>",
      "<CS:organizer><D:href>",
      escape(calendar.owner || ""),
      "</D:href></CS:organizer>",
      "<CS:summary>",
      escape(invitation.summary || ""),
      "</CS:summary>",
      "</CS:invite-notification>",
      "</CS:notification>"
    ]
    |> IO.iodata_to_binary()
  end

  defp stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

  ## --- replying ---------------------------------------------------

  # On acceptance the invitee is told where the calendar now lives in
  # *their* home, which is the whole point of the reply: without a URL
  # they have been granted access to something they cannot address.
  defp reply(conn, document, resource, options) do
    if Enum.any?(document.children, &named?(&1, "invite-accepted")) do
      accepted(conn, document, resource, options)
    else
      send_resp(conn, 200, "")
    end
  end

  defp accepted(conn, document, home, options) do
    case hosturl(document) do
      nil ->
        send_resp(conn, 400, "")

      shared ->
        path = home.path ++ [Path.basename(shared)]
        link(path, shared, options)

        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(200, shared_as(path))
    end
  end

  defp hosturl(document) do
    case find(document, "hosturl") do
      nil -> nil
      element -> href_of(element)
    end
  end

  # The shared calendar appears in the invitee's home as a collection
  # of its own, reporting `CS:shared` so a client can tell it apart
  # from one they own.
  defp link(path, shared, %{store: store, context: context}) do
    if Store.supports?(store, :mkcol) do
      store.mkcol(path, context)

      if Store.supports?(store, :patch) do
        store.patch(
          %Resource{path: path, collection?: true},
          [{:set, {@namespace, "shared-url"}, {:hrefs, [shared]}}],
          context
        )
      end
    end

    :ok
  end

  defp shared_as(path) do
    href = Resource.href(%Resource{path: path, collection?: true})

    ~s(<?xml version="1.0" encoding="utf-8"?><CS:shared-as xmlns:D="DAV:" xmlns:CS="#{@namespace}"><D:href>#{escape(href)}</D:href></CS:shared-as>)
  end

  ## --- reading ----------------------------------------------------

  # A dispatcher that had to read the body to route on passes it
  # along; anything else reads it here.
  defp request_body(conn, %{body: body}), do: {:ok, body, conn}
  defp request_body(conn, _options), do: read_body(conn)

  defp resolve(path, %{store: store, context: context}), do: store.resolve(path, context)

  defp children(element, name), do: Enum.filter(element.children, &named?(&1, name))

  defp find(element, name), do: Enum.find(element.children, &named?(&1, name))

  defp href_of(element) do
    case find(element, "href") do
      nil -> nil
      href -> String.trim(href.text)
    end
  end

  defp text_of(element, name) do
    case find(element, name) do
      nil -> nil
      found -> String.trim(found.text)
    end
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
