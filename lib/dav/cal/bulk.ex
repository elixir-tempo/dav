defmodule Dav.Cal.Bulk do
  @moduledoc """
  Apple's bulk `POST` — many calendar objects in one request.

  A client synchronising a phone has hundreds of events to store and,
  over `PUT`, hundreds of round trips to store them in. Apple's
  CalendarServer answers a `POST` at the calendar collection itself
  and takes them all at once, replying with a `207` that reports each
  one separately: what it was stored as, what its `ETag` is, and — for
  the ones that failed — which precondition refused them. One failure
  does not stop the rest.

  Two request forms, advertised together in the calendar's
  `MM:bulk-requests` property and never anywhere else:

  * **Simple.** The body is one `VCALENDAR` holding components with
    several `UID`s, sent as `text/calendar`. The server divides it —
    one resource per `UID`, carrying only the `VTIMEZONE`s that group
    actually references — and names each resource itself. Every
    component is a *creation*: a `UID` the collection already holds is
    refused with `CALDAV:no-uid-conflict` rather than quietly
    replacing it, because the client never said which resource it
    meant.

  * **CRUD.** The body is an `MM:multiput` document, sent as XML. Each
    `MM:resource` names what to do with one resource: `D:set` with
    `CALDAV:calendar-data` to write it, `MM:delete` to remove it, a
    `D:href` to say which one — and without an `href`, to create a new
    one. `MM:if-match` carries the `D:getetag` the client believes it
    has, which makes each entry conditional on its own.

  ### Two headers

  `X-MobileMe-DAV-Options: return-changed-data` asks for the stored
  form back, but only where it differs from what was sent — which is
  what makes the request worth sending: implicit scheduling rewrites
  an organiser's copy, and a client that assumed its own bytes were
  stored would hold a stale `ETag` for content it has never seen.

  `If: <http://me.com/_namespace/ctag/TOKEN>` makes the whole request
  conditional on the collection not having changed since `TOKEN` — a
  ctag, as `CS:getctag` reports it. A stale token is `412`, and
  nothing is written.

  ### Each entry is an ordinary write

  Every resource goes through `Dav.Web.Write.document/5`, so a bulk
  `POST` is exactly as many `PUT`s as it names: the same validators
  refuse it, and the same hooks deliver the invitations. A bulk
  implementation that wrote straight to the store would be a way of
  organising a meeting without telling the attendees.

  """

  @behaviour Dav.Web.Hook
  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Web.Write
  alias Dav.Xml

  @namespace "http://me.com/_namespace/"
  @calendarserver "http://calendarserver.org/ns/"
  @calendar_type "text/calendar; charset=utf-8"

  # What one request may carry. Both are advertised in
  # `MM:bulk-requests` and both are enforced, because a limit a client
  # can read and the server does not apply is worse than none: it
  # tells the client its request will be accepted.
  @max_resources 100
  @max_bytes 10_485_760

  @doc """
  The `MM:multiput` document element, for callers routing a `POST`.

  ### Returns

  * The qualified name a CRUD bulk request's root element carries.

  ### Examples

      iex> Dav.Cal.Bulk.multiput()
      {"http://me.com/_namespace/", "multiput"}

  """
  @spec multiput() :: Xml.qname()
  def multiput, do: {@namespace, "multiput"}

  @doc """
  Bulk `POST` applies to calendar collections.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for a calendar.

  ### Examples

      iex> Dav.Cal.Bulk.applies?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.Bulk.applies?(nil)
      false

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{} = collection), do: Cal.calendar?(collection)
  def applies?(_absent), do: false

  @doc """
  A write changes nothing here — bulk requests happen only on request.

  ### Arguments

  * `change` is the write, unused.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`.

  ### Examples

      iex> Dav.Cal.Bulk.written(%{}, %{})
      :ok

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  `MM:bulk-requests`, on the collections that accept one.

  Stated on calendars and on nothing else, which is how a client
  learns where it may send a bulk `POST`. The two children name the
  forms this server accepts and the limits it holds each to.

  ### Arguments

  * `resource` is the resource being described.

  * `collection` is the collection holding it, unused.

  * `options` carries the request context, unused.

  ### Returns

  * The property, or nothing for a resource that is not a calendar.

  ### Examples

      iex> calendar = %Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]}
      iex> [{name, {:elements, _namespaces, markup}}] = Dav.Cal.Bulk.properties(calendar, nil, %{})
      iex> name
      {"http://me.com/_namespace/", "bulk-requests"}
      iex> IO.iodata_to_binary(markup) =~ "<MM:crud"
      true

      iex> Dav.Cal.Bulk.properties(%Dav.Web.Resource{path: ["c", "1.ics"]}, nil, %{})
      []

  """
  @impl Dav.Web.Hook
  @spec properties(Resource.t(), Resource.t() | nil, map()) :: [{Xml.qname(), Xml.value()}]
  def properties(%Resource{} = resource, _collection, _options) do
    if Cal.calendar?(resource) do
      [{{@namespace, "bulk-requests"}, {:elements, [@namespace], advertised()}}]
    else
      []
    end
  end

  defp advertised do
    [
      ~s(<MM:simple xmlns:MM="#{@namespace}">),
      limits(),
      "</MM:simple>",
      ~s(<MM:crud xmlns:MM="#{@namespace}">),
      limits(),
      "</MM:crud>"
    ]
  end

  defp limits do
    [
      "<MM:max-resources>",
      Integer.to_string(@max_resources),
      "</MM:max-resources>",
      "<MM:max-bytes>",
      Integer.to_string(@max_bytes),
      "</MM:max-bytes>"
    ]
  end

  @doc """
  Handle a bulk `POST` at a calendar collection.

  ### Arguments

  * `conn` is the request. `Dav.Cal.Post` has already read the body,
    and passes it in `options`.

  * `path` is the calendar's path segments.

  * `options` carries `:store`, `:context`, `:validators`, `:hooks`
    and the body.

  ### Returns

  * The connection, with a `207` naming what became of each resource
    — or the single status that refused the whole request.

  """
  @impl Dav.Web.Method
  @spec call(Plug.Conn.t(), [String.t()], map()) :: Plug.Conn.t()
  def call(conn, path, options) do
    {:ok, body, conn} = request_body(conn, options)

    with {:ok, calendar} <- located(path, options),
         :ok <- bounded(body),
         :ok <- current(conn, calendar, options),
         {:ok, requests} <- requested(body, calendar),
         :ok <- counted(requests) do
      rows = Enum.map(requests, &applied(&1, calendar, returning?(conn), options))

      conn
      |> tagged(calendar, options)
      |> put_resp_content_type("application/xml", "utf-8")
      |> send_resp(207, Xml.multistatus(rows))
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :forbidden} -> send_resp(conn, 403, "")
      {:error, :stale} -> send_resp(conn, 412, "")
      {:error, {_namespace, _local} = condition} -> refused(conn, condition)
      _malformed -> send_resp(conn, 400, "")
    end
  end

  defp request_body(conn, %{body: body}), do: {:ok, body, conn}
  defp request_body(conn, _options), do: read_body(conn)

  defp located(path, %{store: store, context: context}) do
    with {:ok, resource} <- store.resolve(path, context) do
      if Cal.calendar?(resource), do: {:ok, resource}, else: {:error, :forbidden}
    end
  end

  defp bounded(body) do
    if byte_size(body) > @max_bytes, do: {:error, {@namespace, "max-bytes"}}, else: :ok
  end

  defp counted(requests) do
    if length(requests) > @max_resources,
      do: {:error, {@namespace, "max-resources"}},
      else: :ok
  end

  # `If: <http://me.com/_namespace/ctag/TOKEN>` — the whole request is
  # conditional on the collection standing where the client last saw
  # it. Unlike RFC 4918's `If`, which names a resource's own state,
  # this asks about everything in the calendar at once, which is the
  # only question worth asking of a request that writes to all of it.
  defp current(conn, calendar, options) do
    case conn |> get_req_header("if") |> List.first() do
      nil -> :ok
      header -> asked(header, calendar, options)
    end
  end

  defp asked(header, calendar, options) do
    case String.split(header, "/ctag/", parts: 2) do
      [_prefix, rest] ->
        if String.trim_trailing(rest, ">") == ctag(calendar, options),
          do: :ok,
          else: {:error, :stale}

      _not_a_ctag_condition ->
        :ok
    end
  end

  # The ctag and the synchronisation token answer the same question,
  # so `Dav.Cal.Scheduling` reports one as the other and this reads
  # the same value rather than inventing a second one.
  defp ctag(calendar, %{store: store, context: context}) do
    case Store.supports?(store, :sync_token) and store.sync_token(calendar, context) do
      token when is_binary(token) -> token
      _not_synchronised -> nil
    end
  end

  defp tagged(conn, calendar, options) do
    case ctag(calendar, options) do
      nil -> conn
      token -> put_resp_header(conn, "ctag", token)
    end
  end

  defp returning?(conn) do
    conn
    |> get_req_header("x-mobileme-dav-options")
    |> Enum.any?(&String.contains?(&1, "return-changed-data"))
  end

  defp refused(conn, {namespace, local}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error({namespace, local}))
  end

  ## --- what the request asks for -----------------------------------

  # The form is read off the body rather than the `Content-Type`,
  # for the reason `Dav.Cal.Post` routes that way: a client that
  # mislabelled its document deserves an answer about the document.
  defp requested(body, calendar) do
    if String.starts_with?(String.trim_leading(body), "<") do
      crud(body, calendar)
    else
      simple(body, calendar)
    end
  end

  # The simple form names nothing. Every component group is a
  # creation at a name the server chooses, which is why a `UID` the
  # collection already holds is `CALDAV:no-uid-conflict` rather than
  # an update: the client never said which resource it meant.
  defp simple(body, calendar) do
    case ICalendar.parse(body) do
      {:ok, %{name: "VCALENDAR"} = document} ->
        {:ok,
         for {uid, object} <- divided(document) do
           %{
             action: :put,
             path: calendar.path ++ [minted()],
             body: ICalendar.write(object),
             uid: uid,
             etag: nil
           }
         end}

      _not_a_calendar ->
        {:error, :malformed}
    end
  end

  # One calendar per `UID`, in the order the components first appear,
  # each carrying only the `VTIMEZONE`s its own components reference.
  # Copying every zone into every resource would store definitions
  # nothing in the object uses, which RFC 4791 section 4.1 reads as
  # calendar data about zones nobody named.
  defp divided(document) do
    {zones, objects} = Enum.split_with(document.components, &(&1.name == "VTIMEZONE"))
    grouped = Enum.group_by(objects, &uid_of/1)

    for uid <- objects |> Enum.map(&uid_of/1) |> Enum.uniq() do
      components = Map.fetch!(grouped, uid)
      {uid, %{document | components: referenced(zones, components) ++ components}}
    end
  end

  defp referenced(zones, components) do
    named =
      for component <- Enum.flat_map(components, &within/1),
          property <- component.properties,
          zone = Map.get(property.parameters, "TZID"),
          not is_nil(zone),
          into: MapSet.new(),
          do: zone

    Enum.filter(zones, &MapSet.member?(named, identifier(&1)))
  end

  defp within(component), do: [component | Enum.flat_map(component.components, &within/1)]

  defp identifier(zone) do
    case Enum.find(zone.properties, &(&1.name == "TZID")) do
      nil -> nil
      property -> property.value
    end
  end

  defp uid_of(component) do
    case Enum.find(component.properties, &(&1.name == "UID")) do
      nil -> nil
      property -> property.value
    end
  end

  # The CRUD form names each resource itself, or asks the server to
  # name a new one. `MM:if-match` makes an entry conditional on its
  # own `ETag`, so one stale resource refuses one entry rather than
  # the request.
  defp crud(body, calendar) do
    case Xml.parse(body) do
      {:ok, %{name: {@namespace, "multiput"}} = document} ->
        {:ok,
         document |> children({@namespace, "resource"}) |> Enum.map(&instruction(&1, calendar))}

      _not_a_multiput ->
        {:error, :malformed}
    end
  end

  defp instruction(element, calendar) do
    request = %{
      path: addressed(element, calendar),
      etag: conditioned(element),
      body: nil,
      uid: nil
    }

    if find(element, {@namespace, "delete"}) do
      Map.put(request, :action, :delete)
    else
      body = given(element)
      %{request | body: body, uid: identified(body)} |> Map.put(:action, :put)
    end
  end

  # An `href` with no path at all is not a resource in this calendar,
  # and reaches `inside/2` as the empty path it is rather than as a
  # crash on the way there.
  defp addressed(element, calendar) do
    case find(element, {Xml.dav(), "href"}) do
      nil -> calendar.path ++ [minted()]
      href -> href.text |> String.trim() |> URI.parse() |> Map.get(:path) |> parted()
    end
  end

  defp parted(path) when is_binary(path), do: Store.segments(path)
  defp parted(_pathless), do: []

  defp conditioned(element) do
    with %{} = condition <- find(element, {@namespace, "if-match"}),
         %{} = tag <- find(condition, {Xml.dav(), "getetag"}) do
      String.trim(tag.text)
    else
      _unconditional -> nil
    end
  end

  # `D:set` holds the data either directly or inside a `D:prop`; the
  # fixtures use both spellings and CalendarServer accepts both.
  defp given(element) do
    with %{} = set <- find(element, {Xml.dav(), "set"}),
         %{} = data <- deep(set, {Xml.caldav(), "calendar-data"}) do
      String.trim(data.text)
    else
      _nothing_to_write -> nil
    end
  end

  defp identified(nil), do: nil

  defp identified(body) do
    case ICalendar.parse(body) do
      {:ok, document} -> document.components |> Enum.map(&uid_of/1) |> Enum.find(& &1)
      _unreadable -> nil
    end
  end

  defp children(element, name), do: Enum.filter(element.children, &(&1.name == name))

  defp find(element, name), do: Enum.find(element.children, &(&1.name == name))

  defp deep(element, name) do
    Enum.find_value(element.children, fn child ->
      if child.name == name, do: child, else: deep(child, name)
    end)
  end

  defp minted, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".ics"

  ## --- carrying it out ---------------------------------------------

  # One entry's outcome is its own. A `UID` conflict on the third
  # resource refuses the third resource, and the client learns which
  # of the ones it sent are now stored — the whole point of asking in
  # one request rather than twenty.
  defp applied(%{action: :delete} = request, calendar, _returning, options) do
    {here(request), dropped(request, calendar, options)}
  end

  defp applied(%{action: :put} = request, calendar, returning, options) do
    case saved(request, calendar, options) do
      {:ok, resource} ->
        {Resource.href(resource),
         [{"HTTP/1.1 200 OK", row(request, resource, returning, options)}]}

      refusal ->
        {here(request), stated(refusal)}
    end
  end

  defp here(request), do: Resource.href(%Resource{path: request.path})

  defp saved(request, calendar, options) do
    with :ok <- inside(request, calendar),
         :ok <- carried(request),
         :ok <- unchanged(request, options),
         {:ok, _outcome, resource} <-
           Write.document(request.path, request.body, @calendar_type, options) do
      {:ok, resource}
    end
  end

  # An `MM:resource` that neither deletes nor sets any
  # `CALDAV:calendar-data` asks for nothing. Passing its emptiness to
  # the store would write a resource with no body rather than say so.
  defp carried(%{body: body}) when is_binary(body) and body != "", do: :ok
  defp carried(_empty), do: {:error, :forbidden}

  defp dropped(request, calendar, options) do
    with :ok <- inside(request, calendar),
         {:ok, resource} <- resolve(request.path, options),
         :ok <- unchanged(request, options),
         :ok <- Hook.removal(resource, calendar, options),
         held = Write.contents(resource, options) || "",
         properties = kept(resource, options),
         :ok <- options.store.delete(resource, options.context) do
      change = %{
        resource: resource,
        body: held,
        previous: held,
        collection: calendar,
        properties: properties
      }

      Hook.removing(change, options)

      {:status, "HTTP/1.1 200 OK"}
    else
      refusal -> stated(refusal)
    end
  end

  # What a refused entry says for itself. A precondition keeps its
  # name — the client has to be able to tell a `UID` collision from a
  # permission it does not hold, and a bare `403` says neither.
  defp stated({:error, {_namespace, _local} = condition}),
    do: {:status, "HTTP/1.1 403 Forbidden", condition}

  defp stated({:error, :not_found}), do: {:status, "HTTP/1.1 404 Not Found"}
  defp stated({:error, :stale}), do: {:status, "HTTP/1.1 412 Precondition Failed"}
  defp stated({:error, :conflict}), do: {:status, "HTTP/1.1 409 Conflict"}
  defp stated({:error, _other}), do: {:status, "HTTP/1.1 403 Forbidden"}

  # A bulk request writes into the calendar it was sent to. An `href`
  # naming somewhere else is not a resource this request may touch,
  # and following it would let one `POST` reach across the home.
  defp inside(request, calendar) do
    if Enum.drop(request.path, -1) == calendar.path,
      do: :ok,
      else: {:error, :forbidden}
  end

  # `MM:if-match` is `If-Match` per entry: the client writes only over
  # the copy it believes it holds. A resource that is not there yet
  # cannot match a tag, which is the same answer `If-Match` gives.
  defp unchanged(%{etag: nil}, _options), do: :ok

  defp unchanged(request, options) do
    case resolve(request.path, options) do
      {:ok, %Resource{etag: etag}} when etag == request.etag -> :ok
      _absent_or_moved -> {:error, :stale}
    end
  end

  defp resolve(path, %{store: store, context: context}) do
    case store.resolve(path, context) do
      {:ok, resource} -> {:ok, resource}
      _absent -> {:error, :not_found}
    end
  end

  defp kept(resource, %{store: store, context: context}) do
    if Store.supports?(store, :properties), do: store.properties(resource, context), else: %{}
  end

  # What a stored resource is reported as: its validator, the `UID` it
  # holds — which is how a client matches a response to the component
  # it sent, since it did not choose the name — and, only when asked
  # and only when it differs, what the server actually stored.
  defp row(request, resource, returning, options) do
    identity =
      case request.uid do
        nil -> []
        uid -> [{{@calendarserver, "uid"}, uid}]
      end

    tag = [{{Xml.dav(), "getetag"}, resource.etag}]

    tag ++ identity ++ rewritten(request, resource, returning, options)
  end

  # Compared as content rather than as bytes, for the reason
  # `Dav.Web.Plug` compares a `PUT` that way: a store that returns
  # `CRLF` where the client sent `LF` has changed nothing anybody can
  # read, and reporting that as a change would send the whole object
  # back on every write.
  defp rewritten(_request, _resource, false, _options), do: []

  defp rewritten(request, resource, true, options) do
    case Write.contents(resource, options) do
      stored when is_binary(stored) ->
        if lines(stored) == lines(request.body),
          do: [],
          else: [{{Xml.caldav(), "calendar-data"}, stored}]

      _unreadable ->
        []
    end
  end

  defp lines(body), do: body |> String.split(~r/\r?\n/) |> Enum.reject(&(&1 == ""))
end
