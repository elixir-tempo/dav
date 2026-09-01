defmodule Dav.Cal.Attachments do
  @moduledoc """
  Apple's managed attachments — files a calendar object carries.

  A client `POST`s the file itself to the event's URL with
  `?action=attachment-add`, and the server does the bookkeeping: it
  stores the file in the owner's attachment area, names it with a
  `MANAGED-ID`, and writes an `ATTACH` property carrying the id, the
  filename, the media type, the size and the file's URL into the
  targeted components. `attachment-update` replaces the file — under a
  fresh id, so caches holding the old URL stay right — and
  `attachment-remove` takes the property away. Files are per-event
  copies, reference-counted by the event bodies: one is deleted only
  when the last event referencing it lets go.

  Only the calendar's owner may manage or read attachments: the file
  lives under their home, and a `GET` from anybody else is refused.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  import Plug.Conn

  @caldav "urn:ietf:params:xml:ns:caldav"

  # As a validator: a `PUT` may carry `ATTACH;MANAGED-ID=` only for
  # attachments this event's home actually holds — a made-up id, or
  # somebody else's, is refused before anything is stored.
  @impl Dav.Web.Hook
  def applies?(collection), do: Cal.calendar?(collection)

  def validate(body, _collection, path, options) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [_at_least_one | _rest] = claimed <- claimed_ids(calendar) do
      # An id some event in this home carries is the caller's own; one
      # shaped like a real id but carried elsewhere is somebody else's,
      # and the write keeps the attachment as a plain URL — the
      # parameter is stripped after storing. Anything else is made up,
      # and refused.
      known = registry(Enum.drop(path, -2), nil, options)

      if Enum.all?(
           claimed,
           &(Map.has_key?(known, &1) or Regex.match?(~r/^[0-9a-f]{24}$/, &1))
         ),
         do: :ok,
         else: {:error, {@caldav, "valid-managed-id"}}
    else
      _none_claimed_or_unreadable -> :ok
    end
  end

  defp claimed_ids(calendar) do
    for component <- calendar.components,
        component.name != "VTIMEZONE",
        property <- component.properties,
        property.name == "ATTACH",
        id = Map.get(property.parameters, "MANAGED-ID"),
        is_binary(id),
        uniq: true,
        do: id
  end

  # The server owns a managed `ATTACH` property, not the client. A
  # write that altered its parameters or value gets the canonical form
  # restored from the stored file; one reusing an id another event in
  # this home carries gets its own copy of the file, under its own
  # URL, so each reference lives and dies alone; and one referencing
  # somebody else's attachment keeps the URL but loses the
  # `MANAGED-ID` — the id belongs to its owner. Afterwards, files no
  # event references any more are collected.
  @impl Dav.Web.Hook
  def written(%{resource: %{collection?: false} = resource, body: body} = change, options)
      when is_binary(body) do
    home = Enum.drop(resource.path, -2)

    with {:ok, calendar} <- ICalendar.parse(body) do
      known =
        home
        |> registry(resource.path, options)
        |> Map.merge(previously_carried(change, home))

      {components, changed?} =
        Enum.map_reduce(calendar.components, false, fn component, changed? ->
          {kept, touched?} = canonicalized(component, home, known, options)
          {kept, changed? or touched?}
        end)

      if changed? do
        %{store: store, context: context} = options

        store.put(
          resource.path,
          ICalendar.write(%{calendar | components: components}),
          "text/calendar; charset=utf-8",
          context
        )
      end
    end

    collect_garbage(home, options)
  end

  def written(_change, _options), do: :ok

  # The body this write replaced still vouches for the ids it carried:
  # a client restating one of its own attachments with mangled
  # parameters is corrected from it.
  defp previously_carried(%{previous: previous}, home) when is_binary(previous) do
    case ICalendar.parse(previous) do
      {:ok, calendar} -> carried_by(calendar, home)
      _unreadable -> %{}
    end
  end

  defp previously_carried(_change, _home), do: %{}

  defp canonicalized(%{name: "VTIMEZONE"} = zone, _home, _known, _options), do: {zone, false}

  defp canonicalized(component, home, known, options) do
    uid = uid_of(component)

    {properties, changed?} =
      Enum.map_reduce(component.properties, false, fn property, changed? ->
        case restored(property, uid, home, known, options) do
          {:ok, restored} -> {restored, true}
          :unchanged -> {property, changed?}
        end
      end)

    {%{component | properties: properties}, changed?}
  end

  defp uid_of(component) do
    Enum.find_value(component.properties, "unnamed", fn property ->
      property.name == "UID" && property.value
    end)
  end

  defp restored(%{name: "ATTACH"} = property, uid, home, known, options) do
    claimed = Map.get(property.parameters, "MANAGED-ID")
    value_path = dropbox_path(property.value, home)

    cond do
      is_binary(claimed) and Map.has_key?(known, claimed) ->
        canonically(property, claimed, Map.fetch!(known, claimed), uid, home, options)

      is_binary(claimed) ->
        {:ok, %{property | parameters: Map.delete(property.parameters, "MANAGED-ID")}}

      value_path != nil ->
        case id_for_path(known, value_path) do
          nil -> :unchanged
          id -> canonically(property, id, value_path, uid, home, options)
        end

      true ->
        :unchanged
    end
  end

  defp restored(_property, _uid, _home, _known, _options), do: :unchanged

  # The canonical property for this event's copy of the file — copied
  # into the event's own directory first when the id was learned from
  # another event.
  defp canonically(property, id, source, uid, home, options) do
    destination = home ++ ["dropbox", uid, List.last(source)]

    with :ok <- ensured(source, destination, options),
         {:ok, parameters, value} <- canonical(destination, id, options) do
      if property.parameters == parameters and property.value == value,
        do: :unchanged,
        else: {:ok, %{property | parameters: parameters, value: value}}
    else
      _unavailable -> :unchanged
    end
  end

  defp ensured(source, source, _options), do: :ok

  defp ensured(source, destination, %{store: store, context: context}) do
    with :missing <- resolved_or_missing(store, destination, context),
         {:ok, file} <- store.resolve(source, context),
         {:ok, data} <- store.read(file, context) do
      store.mkcol(Enum.drop(destination, -1), context)

      store.put(
        destination,
        IO.iodata_to_binary(data),
        file.content_type || "application/octet-stream",
        context
      )

      :ok
    else
      :ok -> :ok
      _unavailable -> :error
    end
  end

  defp resolved_or_missing(store, path, context) do
    case store.resolve(path, context) do
      {:ok, _held} -> :ok
      _absent -> :missing
    end
  end

  # The authoritative parameters for a copy, read from the file it
  # names: what the client wrote in its calendar does not enter into
  # it.
  defp canonical(path, id, %{store: store, context: context} = options) do
    case store.resolve(path, context) do
      {:ok, file} ->
        parameters = %{
          "FILENAME" => List.last(file.path),
          "FMTTYPE" => file.content_type || "application/octet-stream",
          "SIZE" => Integer.to_string(file.content_length || sized(file, options)),
          "MANAGED-ID" => id
        }

        {:ok, parameters, "/" <> Enum.map_join(file.path, "/", &URI.encode/1)}

      _missing ->
        :error
    end
  end

  defp sized(file, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(file, context) do
      IO.iodata_to_binary(data) |> byte_size()
    else
      _unreadable -> 0
    end
  end

  # Every id some event in the home carries, mapped to the file its
  # `ATTACH` value names. The event bodies are the register: an id is
  # valid exactly while an event carries it.
  defp registry(home, excluded, options) do
    for collection <- collections_of(home, options),
        member <- members_of(collection, options),
        member.path != excluded,
        calendar = read_calendar(member, options),
        calendar != nil,
        {id, file} <- carried_by(calendar, home),
        into: %{},
        do: {id, file}
  end

  defp carried_by(calendar, home) do
    for component <- calendar.components,
        component.name != "VTIMEZONE",
        property <- component.properties,
        property.name == "ATTACH",
        id = Map.get(property.parameters, "MANAGED-ID"),
        is_binary(id),
        file = dropbox_path(property.value, home),
        into: %{},
        do: {id, file}
  end

  defp id_for_path(known, path) do
    Enum.find_value(known, fn {id, file} -> file == path && id end)
  end

  # A value pointing into this home's own attachment area names a file
  # there; anything else is not ours to manage.
  defp dropbox_path(value, home) do
    prefix = "/" <> Enum.map_join(home ++ ["dropbox"], "/", &URI.encode/1) <> "/"

    if is_binary(value) and String.starts_with?(value, prefix) do
      below =
        value
        |> String.replace_prefix(prefix, "")
        |> String.split("/")
        |> Enum.map(&URI.decode/1)

      home ++ ["dropbox" | below]
    end
  end

  # Attachment files are kept alive by reference: while any event in
  # the home points at a file, it stays — an update elsewhere or a
  # deleted event only takes a file with it when it held the last
  # reference.
  defp collect_garbage(home, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :delete),
         {:ok, dropbox} <- store.resolve(home ++ ["dropbox"], context),
         {:ok, held} <- store.children(dropbox, context),
         [_at_least_one | _rest] <- held do
      referenced = referenced_paths(home, options)

      for directory <- held, directory.collection?, do: swept(directory, referenced, options)
    end

    :ok
  end

  defp swept(directory, referenced, %{store: store, context: context} = options) do
    files = members_of(directory, options)

    for file <- files, file.path not in referenced, do: store.delete(file, context)

    if Enum.all?(files, &(&1.path not in referenced)),
      do: store.delete(directory, context)
  end

  # Any `ATTACH` value naming a file in the home's own area counts —
  # with or without its id — so a reference never dangles.
  defp referenced_paths(home, options) do
    for collection <- collections_of(home, options),
        member <- members_of(collection, options),
        calendar = read_calendar(member, options),
        calendar != nil,
        component <- calendar.components,
        component.name != "VTIMEZONE",
        property <- component.properties,
        property.name == "ATTACH",
        path = dropbox_path(property.value, home),
        do: path
  end

  defp collections_of(home, %{store: store, context: context}) do
    with {:ok, root} <- store.resolve(home, context),
         {:ok, children} <- store.children(root, context) do
      for collection <- children,
          collection.collection?,
          List.last(collection.path) != "dropbox",
          do: collection
    else
      _no_home -> []
    end
  end

  defp members_of(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.reject(children, & &1.collection?)
      _nothing -> []
    end
  end

  defp read_calendar(member, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(member, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(data)) do
      calendar
    else
      _unreadable -> nil
    end
  end

  # An event's attachments go with it — unless another event still
  # references them, which the sweep decides.
  @impl Dav.Web.Hook
  def deleted(%{resource: %{collection?: false} = resource}, options) do
    collect_garbage(Enum.drop(resource.path, -2), options)
  end

  def deleted(_change, _options), do: :ok

  @impl Dav.Web.Hook
  def action(action, conn, resource, options)
      when action in ["attachment-add", "attachment-update", "attachment-remove"] do
    {:ok, body, conn} = read_body(conn)

    cond do
      not calendar_object?(resource, options) ->
        {:ok, send_resp(conn, 403, "")}

      not owned_by_caller?(resource, options) ->
        {:ok, refused(conn, {"DAV:", "need-privileges"})}

      true ->
        {:ok, managed(action, conn, resource, body, options)}
    end
  end

  def action(_other, _conn, _resource, _options), do: :unhandled

  # Attachments are private to the home they live in: a `GET` from
  # anybody else is refused, and so is one for an attachment that is
  # not there — the reference answers `403` for the whole area rather
  # than confirming what exists in it.
  @impl Dav.Web.Hook
  def readable(%Resource{path: path}, %{store: store, context: context} = options) do
    case Enum.split_while(path, &(&1 != "dropbox")) do
      {_prefix, []} ->
        :ok

      {prefix, [_dropbox | below]} ->
        cond do
          below == [] -> :ok
          not match?(%Resource{path: ^prefix}, caller_home(options)) -> {:error, :forbidden}
          not match?({:ok, _held}, store.resolve(path, context)) -> {:error, :forbidden}
          true -> :ok
        end
    end
  end

  defp managed("attachment-add", conn, resource, body, options) do
    with :ok <- unaddressed(conn),
         {:ok, calendar} <- held(resource, options),
         :ok <- room_for_another(calendar) do
      {id, url} = stored_file(conn, resource, body, first_uid(calendar), options)

      updated =
        rewrite(calendar, rids_of(conn), fn component ->
          %{component | properties: component.properties ++ [attach(conn, id, url, body)]}
        end)

      write_back(resource, updated, options)

      conn
      |> put_resp_header("location", url)
      |> put_resp_header("cal-managed-id", id)
      |> answered(resource, 201, options)
    else
      {:error, condition} -> refused(conn, condition)
    end
  end

  defp managed("attachment-update", conn, resource, body, options) do
    with {:ok, calendar} <- held(resource, options),
         {:ok, old} <- managed_id(conn, calendar) do
      {id, url} = stored_file(conn, resource, body, first_uid(calendar), options)

      replacement = attach(conn, id, url, body)

      updated =
        rewrite(calendar, :every, fn component ->
          %{component | properties: replaced(component.properties, old, replacement)}
        end)

      write_back(resource, updated, options)
      collect_garbage(Enum.drop(resource.path, -2), options)

      conn
      |> put_resp_header("location", url)
      |> put_resp_header("cal-managed-id", id)
      |> answered(resource, 200, options)
    else
      {:error, condition} -> refused(conn, condition)
    end
  end

  defp managed("attachment-remove", conn, resource, _body, options) do
    with {:ok, calendar} <- held(resource, options),
         {:ok, old} <- managed_id(conn, calendar) do
      updated =
        rewrite(calendar, rids_of(conn), fn component ->
          %{component | properties: Enum.reject(component.properties, &attach_with?(&1, old))}
        end)

      write_back(resource, updated, options)
      collect_garbage(Enum.drop(resource.path, -2), options)
      answered(conn, resource, 200, options)
    else
      {:error, condition} -> refused(conn, condition)
    end
  end

  # Apple's cap, checked the way `max-attendees-per-instance` is: the
  # sixth attachment is refused with the precondition that names the
  # limit.
  @max_attachments 5

  defp room_for_another(calendar) do
    held =
      calendar.components
      |> Enum.reject(&(&1.name == "VTIMEZONE"))
      |> Enum.flat_map(& &1.properties)
      |> Enum.count(&(&1.name == "ATTACH"))

    if held < @max_attachments, do: :ok, else: {:error, {@caldav, "max-attachments"}}
  end

  # Adding takes no `managed-id` — one named here is a claim about an
  # attachment this request is not managing — and no `rid` either: the
  # reference server attaches to the whole event, never to an
  # instance, and refuses the attempt.
  defp unaddressed(conn) do
    query = URI.decode_query(conn.query_string)

    cond do
      Map.has_key?(query, "managed-id") -> {:error, {@caldav, "valid-managed-id-parameter"}}
      Map.has_key?(query, "rid") -> {:error, {@caldav, "valid-rid-parameter"}}
      true -> :ok
    end
  end

  defp managed_id(conn, calendar) do
    stated = conn.query_string |> URI.decode_query() |> Map.get("managed-id")

    if is_binary(stated) and known_id?(calendar, stated),
      do: {:ok, stated},
      else: {:error, {@caldav, "valid-managed-id-parameter"}}
  end

  defp known_id?(calendar, id) do
    calendar.components
    |> Enum.reject(&(&1.name == "VTIMEZONE"))
    |> Enum.flat_map(& &1.properties)
    |> Enum.any?(&attach_with?(&1, id))
  end

  defp replaced(properties, old, replacement) do
    Enum.map(properties, fn property ->
      if attach_with?(property, old), do: replacement, else: property
    end)
  end

  defp attach_with?(property, id) do
    property.name == "ATTACH" and Map.get(property.parameters, "MANAGED-ID") == id
  end

  # The file itself, in the event's own corner of the owner's
  # attachment area. The id is registered by the `ATTACH` property the
  # caller gets back — the event bodies are the register.
  defp stored_file(conn, resource, body, uid, %{store: store, context: context}) do
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    filename = disposed_filename(conn)
    home = Enum.drop(resource.path, -2)
    directory = home ++ ["dropbox", uid]

    store.mkcol(directory, context)
    store.put(directory ++ [filename], body, stated_type(conn), context)

    {id, "/" <> Enum.map_join(directory ++ [filename], "/", &URI.encode/1)}
  end

  defp first_uid(calendar) do
    calendar.components
    |> Enum.reject(&(&1.name == "VTIMEZONE"))
    |> Enum.find_value("unnamed", &uid_of/1)
  end

  defp disposed_filename(conn) do
    conn
    |> get_req_header("content-disposition")
    |> List.first("")
    |> then(&Regex.run(~r/filename="?([^";]+)"?/, &1))
    |> case do
      [_full, name] -> name
      _unstated -> "attachment"
    end
  end

  defp stated_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first("application/octet-stream")
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp attach(conn, id, url, body) do
    %{
      name: "ATTACH",
      parameters: %{
        "FILENAME" => disposed_filename(conn),
        "FMTTYPE" => stated_type(conn),
        "SIZE" => Integer.to_string(byte_size(body)),
        "MANAGED-ID" => id
      },
      value: url
    }
  end

  # Which components take the change: every one, or those the `rid`
  # parameter names — `M` standing for the master, the rest spelled
  # the way their `RECURRENCE-ID`s are.
  defp rids_of(conn) do
    case conn.query_string |> URI.decode_query() |> Map.get("rid") do
      nil -> :every
      stated -> stated |> String.split(",") |> Enum.map(&String.trim/1)
    end
  end

  defp rewrite(calendar, :every, change) do
    components =
      Enum.map(calendar.components, fn component ->
        if component.name == "VTIMEZONE", do: component, else: change.(component)
      end)

    %{calendar | components: components}
  end

  defp rewrite(calendar, rids, change) do
    components =
      Enum.map(calendar.components, fn component ->
        cond do
          component.name == "VTIMEZONE" -> component
          targeted?(component, rids) -> change.(component)
          true -> component
        end
      end)

    %{calendar | components: components}
  end

  defp targeted?(component, rids) do
    case Enum.find_value(component.properties, fn property ->
           property.name == "RECURRENCE-ID" && property.value
         end) do
      nil -> "M" in rids
      rid -> rid in rids
    end
  end

  defp held(%Resource{} = resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, body} <- store.read(resource, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(body)) do
      {:ok, calendar}
    else
      _unreadable -> {:error, {@caldav, "valid-calendar-data"}}
    end
  end

  defp write_back(%Resource{path: path}, calendar, %{store: store, context: context}) do
    store.put(path, ICalendar.write(calendar), "text/calendar; charset=utf-8", context)
  end

  defp answered(conn, resource, status, %{store: store, context: context} = options) do
    with true <- representation?(conn),
         {:ok, current} <- store.resolve(resource.path, context),
         {:ok, data} <- store.read(current, context) do
      conn
      |> stamped_etag(current)
      |> put_resp_content_type("text/calendar", "utf-8")
      |> send_resp(status, IO.iodata_to_binary(data))
    else
      _plain -> conn |> refreshed_etag(resource, options) |> send_resp(status, "")
    end
  end

  defp refreshed_etag(conn, resource, %{store: store, context: context}) do
    case store.resolve(resource.path, context) do
      {:ok, current} -> stamped_etag(conn, current)
      _absent -> conn
    end
  end

  defp stamped_etag(conn, %Resource{etag: etag}) when is_binary(etag) do
    put_resp_header(conn, "etag", etag)
  end

  defp stamped_etag(conn, _resource), do: conn

  defp representation?(conn) do
    conn
    |> get_req_header("prefer")
    |> Enum.any?(&String.contains?(String.downcase(&1), "return=representation"))
  end

  defp refused(conn, {namespace, local}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error({namespace, local}))
  end

  defp calendar_object?(%Resource{collection?: false} = resource, %{
         store: store,
         context: context
       }) do
    case store.resolve(Enum.drop(resource.path, -1), context) do
      {:ok, parent} -> Cal.calendar?(parent)
      _no_parent -> false
    end
  end

  defp calendar_object?(_resource, _options), do: false

  defp owned_by_caller?(%Resource{path: path}, options) do
    case caller_home(options) do
      %Resource{path: home} -> Enum.take(path, length(home)) == home
      _unknown -> false
    end
  end

  # The caller's own calendar home, reached the only way the store
  # offers: a principal has addresses, and an address has a home.
  defp caller_home(%{store: store, context: context} = options) do
    with principal when is_binary(principal) <- Map.get(options, :principal),
         true <- function_exported?(store, :addresses, 2),
         {:ok, addresses} <- store.addresses(principal, context),
         address when is_binary(address) <- List.first(addresses),
         true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context) do
      home
    else
      _unknown_caller -> nil
    end
  end
end
