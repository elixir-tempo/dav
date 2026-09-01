defmodule Dav.Cal.Access do
  @moduledoc """
  Apple's private events — `X-CALENDARSERVER-ACCESS`.

  An owner marks an event `PUBLIC`, `PRIVATE`, `CONFIDENTIAL` or
  `RESTRICTED`, and everyone else's view follows: a private event does
  not exist for them, a confidential one shows only its timing, a
  restricted one its timing, summary and location. The mark is the
  owner's alone to set or change, it survives a rewrite that omits it
  — the server keeps it beside the data rather than in it — and it
  never travels through a scheduling Outbox.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Cal
  alias Dav.Cal.Delegation
  alias Dav.Cal.ICalendar
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @calendarserver "http://calendarserver.org/ns/"
  @access "X-CALENDARSERVER-ACCESS"
  @levels ~w(PUBLIC PRIVATE CONFIDENTIAL RESTRICTED)

  # What a non-owner is shown, by level. `PUBLIC` and no mark show
  # everything; `PRIVATE` shows nothing at all.
  @confidential ~w(UID RECURRENCE-ID SEQUENCE DTSTAMP DTSTART DTEND DURATION DUE
                   RRULE RDATE EXDATE EXRULE CREATED LAST-MODIFIED STATUS TRANSP)
  @restricted @confidential ++ ~w(SUMMARY LOCATION)

  @doc """
  Access applies to calendar collections.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for a calendar.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(collection), do: Cal.calendar?(collection)

  @doc """
  Whether a write respects the resource's access mark.

  ### Arguments

  * `body` is the incoming calendar data.

  * `collection` is the calendar written into.

  * `path` is where the write lands.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok`, or `{:error, qname}` — a non-owner touching the mark, or
    writing over an event marked away from them.

  """
  @spec validate(binary(), Resource.t() | nil, [String.t()], map()) ::
          :ok | {:error, {String.t(), String.t()}}
  def validate(body, collection, path, options) do
    stated = stated_level(body)
    held = held_level(path, options)

    cond do
      owner_writing?(collection, options) ->
        :ok

      # The mark keeps strangers out before it keeps them honest: an
      # event marked anything but `PUBLIC` cannot be overwritten by
      # anyone else, whatever their grant says.
      held in ~w(PRIVATE CONFIDENTIAL RESTRICTED) ->
        {:error, {Xml.dav(), "need-privileges"}}

      # Only the owner sets or changes the mark.
      stated != nil and stated != held ->
        {:error, {@calendarserver, "valid-access-restriction-change"}}

      true ->
        :ok
    end
  end

  @doc """
  A collection may be created inside anything access minds about.

  ### Arguments

  * `collection` is the parent, unused.

  ### Returns

  * `:ok`.

  """
  @spec permit_collection(Resource.t() | nil) :: :ok
  def permit_collection(_collection), do: :ok

  @doc """
  Keep the access mark beside the data rather than in it.

  ### Arguments

  * `change` is the write.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  def written(%{resource: %{collection?: false} = resource, body: body}, options)
      when is_binary(body) do
    with {:ok, calendar} <- ICalendar.parse(body),
         stated when stated != nil <- calendar_level(calendar) do
      remember(resource, stated, options)
      restate(resource, options)
    end

    :ok
  end

  def written(_change, _options), do: :ok

  @doc """
  Present a body as its access mark allows.

  ### Arguments

  * `resource` is the resolved resource.

  * `body` is the stored body.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `{:ok, body}` — whole for the owner, marked and possibly filtered
    for anyone else — or `{:error, :forbidden}` for a private event
    read by somebody it does not exist for.

  """
  @impl Dav.Web.Hook
  @spec disclosed(Resource.t(), binary(), map()) :: {:ok, binary()} | {:error, :forbidden}
  def disclosed(%Resource{collection?: false} = resource, body, options) do
    case held_level(resource.path, options) do
      nil -> {:ok, body}
      level -> presented(level, resource, body, options)
    end
  end

  def disclosed(_resource, body, _options), do: {:ok, body}

  defp presented(level, resource, body, options) do
    cond do
      owner_reading?(resource, options) -> {:ok, marked(body, level)}
      level == "PRIVATE" -> {:error, :forbidden}
      level == "PUBLIC" -> {:ok, marked(body, level)}
      true -> {:ok, body |> filtered(level) |> marked(level)}
    end
  end

  @doc """
  Whether the caller may read this resource at all.

  ### Arguments

  * `resource` is the resolved resource.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `:ok`, or `{:error, :forbidden}` for somebody else's private
    event.

  """
  @impl Dav.Web.Hook
  @spec readable(Resource.t(), map()) :: :ok | {:error, :forbidden}
  def readable(%Resource{collection?: false} = resource, options) do
    if held_level(resource.path, options) == "PRIVATE" and
         not owner_reading?(resource, options),
       do: {:error, :forbidden},
       else: :ok
  end

  def readable(_resource, _options), do: :ok

  @doc """
  The access level held for a stored object, if any.

  ### Arguments

  * `resource` is the resolved object.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `"PUBLIC"`, `"PRIVATE"`, `"CONFIDENTIAL"` or `"RESTRICTED"`, or
    `nil` when the object carries no mark.

  """
  @spec level(Resource.t(), map()) :: String.t() | nil
  def level(%Resource{path: path}, options), do: held_level(path, options)

  # --- levels -------------------------------------------------------

  defp stated_level(body) do
    case ICalendar.parse(body) do
      {:ok, calendar} -> calendar_level(calendar)
      _unreadable -> nil
    end
  end

  defp calendar_level(calendar) do
    top =
      Enum.find_value(calendar.properties, fn property ->
        property.name == @access && property.value
      end)

    top ||
      Enum.find_value(calendar.components, fn component ->
        component.name != "VTIMEZONE" &&
          Enum.find_value(component.properties, fn property ->
            property.name == @access && property.value
          end)
      end)
  end

  defp held_level(path, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         {:ok, %Resource{} = held} <- store.resolve(path, context),
         %{} = properties <- store.properties(held, context),
         level when level in @levels <- Map.get(properties, {@calendarserver, "access"}) do
      level
    else
      _unmarked -> nil
    end
  end

  defp remember(%Resource{} = resource, level, %{store: store, context: context}) do
    if Store.supports?(store, :patch) do
      store.patch(resource, [{:set, {@calendarserver, "access"}, level}], context)
    end
  end

  # The stored data carries no mark: what the server keeps beside the
  # data is re-said on every read, so a rewrite that omits it changes
  # nothing. Stripped from the copy as *stored* — the other hooks may
  # have already canonicalised it, and their work stands.
  defp restate(%Resource{} = resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :put),
         true <- Store.supports?(store, :read),
         {:ok, held} <- store.read(resource, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(held)) do
      cleaned = %{
        calendar
        | properties: Enum.reject(calendar.properties, &(&1.name == @access)),
          components: Enum.map(calendar.components, &without_mark/1)
      }

      store.put(
        resource.path,
        ICalendar.write(cleaned),
        "text/calendar; charset=utf-8",
        context
      )
    end
  end

  defp without_mark(%{name: "VTIMEZONE"} = zone), do: zone

  defp without_mark(component) do
    %{component | properties: Enum.reject(component.properties, &(&1.name == @access))}
  end

  # --- presentation -------------------------------------------------

  defp marked(body, level) do
    case ICalendar.parse(body) do
      {:ok, calendar} ->
        stamp = %{name: @access, parameters: %{}, value: level}
        ICalendar.write(%{calendar | properties: calendar.properties ++ [stamp]})

      _unreadable ->
        body
    end
  end

  defp filtered(body, level) do
    keep = if level == "RESTRICTED", do: @restricted, else: @confidential

    case ICalendar.parse(body) do
      {:ok, calendar} ->
        components = Enum.map(calendar.components, &shown_part(&1, keep))
        ICalendar.write(%{calendar | components: components})

      _unreadable ->
        body
    end
  end

  defp shown_part(%{name: "VTIMEZONE"} = zone, _keep), do: zone

  defp shown_part(component, keep) do
    %{
      component
      | properties: Enum.filter(component.properties, &(&1.name in keep)),
        components: []
    }
  end

  # --- who ----------------------------------------------------------

  defp owner_writing?(collection, options) do
    owner =
      case collection do
        %Resource{owner: owner} when is_binary(owner) -> owner
        _unowned -> nil
      end

    owner == nil or
      Delegation.authorized_writer?(Map.get(options, :principal), owner, options)
  end

  defp owner_reading?(%Resource{path: path}, %{store: store, context: context} = options) do
    case store.resolve(Enum.drop(path, -1), context) do
      {:ok, %Resource{owner: owner}} when is_binary(owner) ->
        Delegation.authorized_writer?(Map.get(options, :principal), owner, options)

      _unowned ->
        true
    end
  end
end
