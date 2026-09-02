defmodule Dav.Cal.Split do
  @moduledoc """
  Apple's recurrence splitting — `POST ?action=split&rid=`.

  A client that wants to change a recurring event "from now on"
  without disturbing its history asks the server to divide it: the
  original resource keeps its `UID` and becomes the part from `rid`
  onward, and a new resource holds the past under a fresh `UID`, its
  rule closed with `UNTIL` just before the first onward instance. The
  two halves reference each other through
  `RELATED-TO;RELTYPE=X-CALENDARSERVER-RECURRENCE-SET`, the response
  names the new resource in a `Split-Component-URL` header, and
  `Prefer: return=representation` answers with both halves' `ETag`s
  and bodies in a multistatus instead of a bare `204`.

  """

  @behaviour Dav.Web.Hook

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @calendarserver "http://calendarserver.org/ns/"
  @relation "X-CALENDARSERVER-RECURRENCE-SET"
  @calendar_type "text/calendar; charset=utf-8"

  @doc """
  Splitting applies to calendar collections.

  ### Arguments

  * `collection` is the collection being written into.

  ### Returns

  * `true` for a calendar.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(collection), do: Cal.calendar?(collection)

  @doc """
  A write changes nothing here — splits happen only on request.

  ### Arguments

  * `change` is the write, unused.

  * `options` carries the request context, unused.

  ### Returns

  * `:ok`.

  """
  @impl Dav.Web.Hook
  @spec written(map(), map()) :: :ok
  def written(_change, _options), do: :ok

  @doc """
  Handle `POST ?action=split`.

  ### Arguments

  * `action` is the query parameter's value; only `"split"` is
    claimed.

  * `conn` is the request.

  * `resource` is the resolved calendar object.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `{:ok, conn}` with the response sent, or `:unhandled`.

  """
  @impl Dav.Web.Hook
  @spec action(String.t(), Plug.Conn.t(), Resource.t(), map()) ::
          {:ok, Plug.Conn.t()} | :unhandled
  def action("split", conn, %Resource{collection?: false} = resource, options) do
    {:ok, _body, conn} = read_body(conn)
    query = URI.decode_query(conn.query_string)

    {:ok, split(conn, resource, query, options)}
  end

  def action(_other, _conn, _resource, _options), do: :unhandled

  defp split(conn, resource, query, options) do
    with {:ok, rid} <- rid_of(Map.get(query, "rid")),
         {:ok, held} <- body_of(resource, options),
         {:ok, calendar} <- ICalendar.parse(held),
         :ok <- tag_matches(conn, resource, options),
         {:ok, {onward, behind}} <- severable(calendar, rid),
         {:ok, past_uid} <- past_name(Map.get(query, "uid"), resource, options) do
      cut = %{rid: rid, onward: onward, behind: behind, past_uid: past_uid, relid: minted()}
      {future, past} = divided(calendar, cut)

      {_future_res, _future_body, past_res, _past_body} =
        stored = stow(resource, future, past, options)

      if property(master_of(calendar), "ORGANIZER") do
        restamp(resource.path, options)
        restamp(past_res.path, options)
        fanned_out(resource, calendar, cut, options)
      end

      answered(conn, stored, options)
    else
      {:error, :schedule_tag} -> send_resp(conn, 412, "")
      {:error, {_namespace, _local} = condition} -> refused(conn, condition)
      _unreadable -> send_resp(conn, 404, "")
    end
  end

  # RFC 6638 section 3.2.10 applies to a split the way it applies to
  # a write: a client conditional on the `Schedule-Tag` splits only
  # the copy it thinks it has.
  defp tag_matches(conn, resource, options) do
    with :ok <- etag_matches(conn, resource) do
      case get_req_header(conn, "if-schedule-tag-match") do
        [] -> :ok
        [asked | _rest] -> asked_tag_matches(asked, resource, options)
      end
    end
  end

  defp asked_tag_matches(asked, resource, options) do
    if asked == held_tag(resource, options), do: :ok, else: {:error, :schedule_tag}
  end

  defp etag_matches(conn, resource) do
    case get_req_header(conn, "if-match") do
      [] -> :ok
      [asked | _rest] -> if asked in [resource.etag, "*"], do: :ok, else: {:error, :schedule_tag}
    end
  end

  defp held_tag(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(resource, context),
         tag when is_binary(tag) <- Map.get(properties, {Xml.caldav(), "schedule-tag"}) do
      tag
    else
      _untagged -> nil
    end
  end

  # The `rid` names a moment in iCalendar's own spelling — a date, a
  # floating time or a UTC time. Anything else is not a moment.
  defp rid_of(nil), do: {:error, {Xml.caldav(), "valid-rid-parameter"}}

  defp rid_of(rid) do
    if rid =~ ~r/^\d{8}(T\d{6}Z?)?$/,
      do: {:ok, rid},
      else: {:error, {Xml.caldav(), "valid-rid-parameter"}}
  end

  defp body_of(resource, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, held} <- store.read(resource, context) do
      {:ok, IO.iodata_to_binary(held)}
    else
      _unreadable -> :error
    end
  end

  # --- what may be split ---------------------------------------------

  # A split needs a recurring master whose form matches the `rid` —
  # comparing a floating moment against UTC instances answers nothing
  # — with at least one instance behind the cut and one at or after
  # it.
  defp severable(calendar, rid) do
    invalid = {:error, {@calendarserver, "valid-split"}}

    with %{} = master <- master_of(calendar),
         %{value: template} <- property(master, "DTSTART"),
         true <- recurring?(master),
         true <- same_form?(rid, template) do
      {:ok, window} = TimeRange.bounds({template, horizon(rid)})

      spelled =
        master
        |> TimeRange.instances_in(window)
        |> Enum.map(fn {_recurrence, instance, _until} -> spelled(instance, template) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      onward = Enum.find(spelled, &(&1 >= rid))
      past = Enum.count(spelled, &(&1 < rid))

      if onward && past > 0,
        do: {:ok, {onward, past}},
        else: invalid
    else
      _not_severable -> invalid
    end
  end

  defp master_of(calendar) do
    Enum.find(
      calendar.components,
      &(&1.name != "VTIMEZONE" and is_nil(property(&1, "RECURRENCE-ID")))
    )
  end

  defp recurring?(master) do
    Enum.any?(master.properties, &(&1.name in ~w(RRULE RDATE)))
  end

  defp same_form?(rid, template) do
    String.contains?(rid, "T") == String.contains?(template, "T") and
      String.ends_with?(rid, "Z") == String.ends_with?(template, "Z")
  end

  # Enumeration needs a far edge. Three years past the cut finds the
  # next instance of any rule a calendar client writes; a rule that
  # produces nothing for three years has nothing to split onward.
  defp horizon(rid) do
    year = rid |> String.slice(0, 4) |> String.to_integer()

    "#{year + 3}#{String.slice(rid, 4, 4)}" <>
      if(String.contains?(rid, "T"), do: "T000000" <> utc_suffix(rid), else: "")
  end

  defp utc_suffix(rid), do: if(String.ends_with?(rid, "Z"), do: "Z", else: "")

  # An instance spelled the way the master's `DTSTART` is: a date for
  # a date, floating for floating, UTC for UTC.
  defp spelled(instance, template) do
    case Tempo.to_elixir(instance) do
      {:ok, %Date{} = date} ->
        Calendar.strftime(date, "%Y%m%d")

      {:ok, moment} ->
        cond do
          not String.contains?(template, "T") -> Calendar.strftime(moment, "%Y%m%d")
          String.ends_with?(template, "Z") -> Calendar.strftime(moment, "%Y%m%dT%H%M%SZ")
          true -> Calendar.strftime(moment, "%Y%m%dT%H%M%S")
        end

      _unconvertible ->
        nil
    end
  end

  defp property(component, name), do: Enum.find(component.properties, &(&1.name == name))

  defp minted, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :upper)

  # A client may choose the past part's `UID` — but not one already
  # naming an event here, the one being split included.
  defp past_name(nil, _resource, _options), do: {:ok, minted()}

  defp past_name(uid, resource, %{store: store, context: context} = options) do
    taken =
      case store.resolve(Enum.drop(resource.path, -1), context) do
        {:ok, calendar} ->
          case store.children(calendar, context) do
            {:ok, children} ->
              children
              |> Enum.reject(& &1.collection?)
              |> Enum.any?(&holds_uid?(&1, uid, options))

            _nothing ->
              false
          end

        _no_calendar ->
          false
      end

    if taken, do: {:error, {@calendarserver, "valid-split"}}, else: {:ok, uid}
  end

  defp holds_uid?(object, uid, options) do
    with {:ok, held} <- body_of(object, options),
         {:ok, calendar} <- ICalendar.parse(held) do
      Enum.any?(calendar.components, fn component ->
        match?(%{value: ^uid}, property(component, "UID"))
      end)
    else
      _unreadable -> false
    end
  end

  # --- the division --------------------------------------------------

  defp divided(calendar, cut) do
    %{rid: rid, onward: onward, behind: behind, past_uid: past_uid, relid: relid} = cut
    zones = Enum.filter(calendar.components, &(&1.name == "VTIMEZONE"))
    dated = Enum.reject(calendar.components, &(&1.name == "VTIMEZONE"))
    master = master_of(calendar)
    %{value: template} = property(master, "DTSTART")
    scheduled? = property(master, "ORGANIZER") != nil

    {past_overrides, future_overrides} =
      dated
      |> Enum.reject(&(&1 == master))
      |> Enum.split_with(fn override ->
        case property(override, "RECURRENCE-ID") do
          %{value: value} -> value < rid
          nil -> false
        end
      end)

    future_master =
      master
      |> restarted(onward, template)
      |> recounted(behind)

    past_master =
      master
      |> undated(template)
      |> closed(until(onward, template))
      |> renamed(past_uid)

    future =
      %{
        calendar
        | components: zones ++ Enum.map([future_master | future_overrides], &related(&1, relid))
      }
      |> sequenced(scheduled?)

    past =
      %{
        calendar
        | components:
            zones ++
              Enum.map(
                [past_master | Enum.map(past_overrides, &renamed(&1, past_uid))],
                &related(&1, relid)
              )
      }
      |> sequenced(scheduled?)

    {future, past}
  end

  # A scheduled split is an organiser's change, and every participant
  # is told anew — the `SEQUENCE` rises on both halves the way it
  # rises on any reschedule.
  defp sequenced(calendar, false), do: calendar

  defp sequenced(calendar, true) do
    components =
      Enum.map(calendar.components, fn component ->
        if component.name == "VTIMEZONE", do: component, else: raised(component)
      end)

    %{calendar | components: components}
  end

  defp raised(component) do
    case property(component, "SEQUENCE") do
      nil ->
        stamp = %{name: "SEQUENCE", parameters: %{}, value: "1"}
        %{component | properties: component.properties ++ [stamp]}

      %{value: value} = found ->
        raised = %{found | value: Integer.to_string(String.to_integer(value) + 1)}

        %{component | properties: replaced(component.properties, found, raised)}
    end
  end

  defp replaced(properties, from, to) do
    Enum.map(properties, fn property -> if property == from, do: to, else: property end)
  end

  # The rewritten `DTSTART` states a date as a bare date — the
  # reference drops the redundant `VALUE=DATE` on both halves.
  defp restarted(master, onward, template) do
    properties =
      Enum.map(master.properties, fn property ->
        if property.name == "DTSTART",
          do: %{property | value: onward, parameters: dated(property.parameters, template)},
          else: property
      end)

    %{master | properties: properties}
  end

  defp undated(master, template) do
    properties =
      Enum.map(master.properties, fn property ->
        if property.name == "DTSTART",
          do: %{property | parameters: dated(property.parameters, template)},
          else: property
      end)

    %{master | properties: properties}
  end

  defp dated(parameters, template) do
    if String.contains?(template, "T"), do: parameters, else: %{}
  end

  # A counted rule splits its count: the past part swaps `COUNT` for
  # `UNTIL`, and the future part keeps what the past did not spend.
  defp recounted(master, behind) do
    properties =
      Enum.map(master.properties, fn property ->
        if property.name == "RRULE",
          do: %{property | value: spent(property.value, behind)},
          else: property
      end)

    %{master | properties: properties}
  end

  defp spent(rule, behind) do
    case Regex.run(~r/COUNT=(\d+)/, rule) do
      [_whole, count] ->
        String.replace(rule, ~r/COUNT=\d+/, "COUNT=#{String.to_integer(count) - behind}")

      nil ->
        rule
    end
  end

  # The past part's rule ends just before the first onward instance —
  # one second before a moment, one day before a date.
  defp until(onward, template) do
    if String.contains?(template, "T") do
      <<year::binary-4, month::binary-2, day::binary-2, "T", hh::binary-2, mm::binary-2,
        ss::binary-2, _rest::binary>> = onward

      {:ok, moment} =
        NaiveDateTime.new(
          String.to_integer(year),
          String.to_integer(month),
          String.to_integer(day),
          String.to_integer(hh),
          String.to_integer(mm),
          String.to_integer(ss)
        )

      spelled = Calendar.strftime(NaiveDateTime.add(moment, -1), "%Y%m%dT%H%M%S")
      spelled <> utc_suffix(template)
    else
      <<year::binary-4, month::binary-2, day::binary-2>> = onward

      {:ok, date} =
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))

      Calendar.strftime(Date.add(date, -1), "%Y%m%d")
    end
  end

  defp closed(master, until) do
    properties =
      Enum.map(master.properties, fn property ->
        if property.name == "RRULE" do
          rule = property.value |> String.replace(~r/;?COUNT=\d+/, "")
          %{property | value: rule <> ";UNTIL=" <> until}
        else
          property
        end
      end)

    %{master | properties: properties}
  end

  defp renamed(component, uid) do
    properties =
      Enum.map(component.properties, fn property ->
        if property.name == "UID", do: %{property | value: uid}, else: property
      end)

    %{component | properties: properties}
  end

  defp related(component, relid) do
    stamp = %{name: "RELATED-TO", parameters: %{"RELTYPE" => @relation}, value: relid}

    %{component | properties: component.properties ++ [stamp]}
  end

  # --- the scheduled fan-out -----------------------------------------

  # An organiser's split reaches every attendee: their stored copy is
  # divided the same way — their own alarms and answers intact on both
  # halves — and their Inbox hears about each half. The organiser's
  # own halves get fresh `Schedule-Tag`s, exactly as any organiser
  # change moves them.
  defp fanned_out(_resource, calendar, cut, options) do
    master = master_of(calendar)

    with %{value: organizer} <- property(master, "ORGANIZER") do
      uid = value_of(master, "UID")

      for attendee <- attendees_of(master, organizer, options) do
        divided_for(attendee, uid, cut, calendar, options)
      end
    end

    :ok
  end

  defp value_of(component, name) do
    case property(component, name) do
      nil -> nil
      found -> found.value
    end
  end

  defp attendees_of(master, organizer, options) do
    same = canonical(organizer, options)

    master.properties
    |> Enum.filter(&(&1.name == "ATTENDEE"))
    |> Enum.map(& &1.value)
    |> Enum.reject(&(canonical(&1, options) == same))
    |> Enum.uniq_by(&canonical(&1, options))
  end

  defp canonical(address, %{store: store, context: context}) do
    with true <- Store.supports?(store, :canonical_address),
         {:ok, spelled} <- store.canonical_address(address, context) do
      String.downcase(spelled)
    else
      _unknown -> String.downcase(address)
    end
  end

  defp divided_for(attendee, uid, cut, organizer_calendar, options) do
    %{store: store, context: context} = options

    with true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{} = home} <- store.principal(attendee, context),
         {calendar, object} when not is_nil(object) <- copy_of(home, uid, options),
         {:ok, held} <- body_of(object, options),
         {:ok, theirs} <- ICalendar.parse(held) do
      {future, past} = divided(theirs, cut)
      past_path = Enum.drop(object.path, -1) ++ [past_leaf()]

      store.put(object.path, ICalendar.write(future), @calendar_type, context)
      store.put(past_path, ICalendar.write(past), @calendar_type, context)
      restamp(object.path, options)
      restamp(past_path, options)
      told(home, organizer_calendar, cut, options)
      calendar
    else
      _no_local_copy -> :ok
    end
  end

  defp copy_of(home, uid, %{store: store, context: context} = options) do
    calendars =
      case store.children(home, context) do
        {:ok, children} -> Enum.filter(children, &Cal.calendar?/1)
        _nothing -> []
      end

    Enum.find_value(calendars, {nil, nil}, fn calendar ->
      case held_object(calendar, uid, options) do
        nil -> nil
        object -> {calendar, object}
      end
    end)
  end

  defp held_object(calendar, uid, %{store: store, context: context} = options) do
    case store.children(calendar, context) do
      {:ok, children} ->
        Enum.find(children, &(not &1.collection? and holds_uid?(&1, uid, options)))

      _nothing ->
        nil
    end
  end

  # Both halves land in the attendee's Inbox as `REQUEST`s — the
  # message copies, alarms left out.
  defp told(home, organizer_calendar, cut, options) do
    %{store: store, context: context} = options

    with {:ok, children} <- store.children(home, context),
         %Resource{} = inbox <- Enum.find(children, &Schedule.inbox?/1) do
      {future, past} = divided(organizer_calendar, cut)

      for half <- [future, past] do
        body = ICalendar.write(announced(half))
        store.put(inbox.path ++ [past_leaf()], body, @calendar_type, context)
      end
    end

    :ok
  end

  defp announced(calendar) do
    method = %{name: "METHOD", parameters: %{}, value: "REQUEST"}

    components =
      Enum.map(calendar.components, fn component ->
        if component.name == "VTIMEZONE",
          do: component,
          else: %{
            component
            | components: Enum.reject(component.components, &(&1.name == "VALARM"))
          }
      end)

    %{calendar | properties: calendar.properties ++ [method], components: components}
  end

  defp restamp(path, %{store: store, context: context}) do
    with true <- Store.supports?(store, :patch),
         {:ok, %Resource{} = held} <- store.resolve(path, context) do
      tag = ~s("#{:erlang.phash2({path, System.unique_integer()})}")
      store.patch(held, [{:set, {Xml.caldav(), "schedule-tag"}, tag}], context)
    end

    :ok
  end

  # --- storing and answering -----------------------------------------

  defp stow(resource, future, past, %{store: store, context: context}) do
    future_body = ICalendar.write(future)
    past_body = ICalendar.write(past)
    past_path = Enum.drop(resource.path, -1) ++ [past_leaf()]

    store.put(resource.path, future_body, @calendar_type, context)
    store.put(past_path, past_body, @calendar_type, context)

    {resolved(resource.path, store, context), future_body, resolved(past_path, store, context),
     past_body}
  end

  defp past_leaf, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> ".ics"

  defp resolved(path, store, context) do
    case store.resolve(path, context) do
      {:ok, %Resource{} = found} -> found
      _missing -> %Resource{path: path}
    end
  end

  defp answered(conn, {future_res, future_body, past_res, past_body}, options) do
    conn = put_resp_header(conn, "split-component-url", Resource.href(past_res))

    if representation?(conn) do
      rows = [
        row(future_res, future_body, options),
        row(past_res, past_body, options)
      ]

      conn
      |> put_resp_content_type("application/xml", "utf-8")
      |> send_resp(207, Xml.multistatus(rows))
    else
      send_resp(conn, 204, "")
    end
  end

  # Each half's row: its `ETag`, its body — and its `Schedule-Tag`,
  # when it has one, so a client can go straight back to conditional
  # writes on both halves.
  defp row(resource, body, options) do
    tagged =
      case held_tag(resource, options) do
        nil -> []
        tag -> [{{Xml.caldav(), "schedule-tag"}, tag}]
      end

    properties =
      [{{Xml.dav(), "getetag"}, resource.etag}, {{Xml.caldav(), "calendar-data"}, body}] ++
        tagged

    {Resource.href(resource), [{"HTTP/1.1 200 OK", properties}]}
  end

  defp representation?(conn) do
    conn
    |> get_req_header("prefer")
    |> Enum.any?(&String.contains?(&1, "return=representation"))
  end

  defp refused(conn, {namespace, local}) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error({namespace, local}))
  end
end
