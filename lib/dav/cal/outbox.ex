defmodule Dav.Cal.Outbox do
  @moduledoc """
  `POST` on a scheduling Outbox — RFC 6638 sections 3 and 5.

  The one place a CalDAV client asks the server a question about other
  people rather than about storage: *"when are these calendar users
  busy?"*. The request is an iTIP `VFREEBUSY` with `METHOD:REQUEST`
  naming an `ORGANIZER` and one or more `ATTENDEE`s; the answer is a
  `CALDAV:schedule-response` carrying one `VFREEBUSY` per attendee.

      POST /calendars/users/alice/outbox/ HTTP/1.1
      Content-Type: text/calendar

      BEGIN:VCALENDAR
      METHOD:REQUEST
      BEGIN:VFREEBUSY
      ORGANIZER:mailto:alice@example.com
      ATTENDEE:mailto:bob@example.com
      DTSTART:20260601T000000Z
      DTEND:20260701T000000Z
      END:VFREEBUSY
      END:VCALENDAR

  ### A status per recipient, not one for the request

  Every recipient gets its own `CALDAV:request-status`, because the
  answers genuinely differ: one attendee may be unknown to this server
  while the next is answered in full. A single status for the whole
  request would tell the organiser nothing about which of five people
  it could not answer for.

  Recipients this server does not host are reported `3.7;Invalid
  calendar user` rather than being omitted — an absent recipient is
  indistinguishable from one the client forgot to ask about.

  ### What it needs of a store

  `c:Dav.Web.Store.resolve/2` and `c:Dav.Web.Store.children/2` to find
  a recipient's calendars, and `c:Dav.Web.Store.read/2` to see what is
  in them. The busy time itself is computed by `Dav.Cal.TimeRange`, so
  recurrence is expanded the same way `calendar-query` expands it.

  """

  @behaviour Dav.Web.Method

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.FreeBusy
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Web.Store
  alias Dav.Xml

  # iTIP request statuses, RFC 5546 section 3.6.
  @success "2.0;Success"
  @invalid_user "3.7;Invalid calendar user"

  @impl Dav.Web.Method
  def call(conn, path, options) do
    with {:ok, resource} <- resolve(path, options),
         :ok <- outbox(resource),
         {:ok, body, conn} <- read_body(conn),
         :ok <- media_type(conn),
         {:ok, request} <- freebusy(body) do
      respond(conn, request, options)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :not_outbox} -> send_resp(conn, 403, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # RFC 6638 section 5.2 gives this method its own preconditions, and
  # naming them is the whole value: a bare `400` tells a client its
  # request was wrong, while `CALDAV:valid-scheduling-message` tells it
  # the body was not an iTIP message and `CALDAV:valid-organizer` that
  # the ORGANIZER was not one it may act for.
  defp precondition(conn, condition) do
    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(403, Xml.error(condition))
  end

  defp media_type(conn) do
    type = conn |> get_req_header("content-type") |> List.first() || "text/calendar"

    if calendar_type?(type), do: :ok, else: {:error, caldav("supported-calendar-data")}
  end

  defp calendar_type?(type) do
    type |> String.split(";") |> List.first() |> String.trim() |> String.downcase() ==
      "text/calendar"
  end

  defp caldav(name), do: {Xml.caldav(), name}

  defp resolve(path, %{store: store, context: context}) do
    store.resolve(path, context)
  end

  # "The resource identified by the Request-URI MUST be a resource
  # collection of type CALDAV:schedule-outbox."
  defp outbox(resource) do
    if Schedule.outbox?(resource), do: :ok, else: {:error, :not_outbox}
  end

  # The body must be a VFREEBUSY with METHOD:REQUEST. Anything else is
  # a different scheduling operation and not this one.
  defp freebusy(body) do
    case ICalendar.parse(body) do
      {:ok, %{name: "VCALENDAR"} = calendar} -> scheduling_message(calendar)
      _unreadable -> {:error, caldav("valid-calendar-data")}
    end
  end

  # "The request body MUST contain a VFREEBUSY calendar component with
  # the METHOD iCalendar property set to REQUEST." A body that is valid
  # iCalendar but not an iTIP message fails a different precondition
  # from one that is not iCalendar at all.
  defp scheduling_message(calendar) do
    component = Enum.find(calendar.components, &(&1.name == "VFREEBUSY"))

    cond do
      property(calendar, "METHOD") != "REQUEST" ->
        {:error, caldav("valid-scheduling-message")}

      is_nil(component) ->
        {:error, caldav("valid-scheduling-message")}

      is_nil(property(component, "ORGANIZER")) ->
        {:error, caldav("valid-organizer")}

      true ->
        {:ok, component}
    end
  end

  defp respond(conn, request, options) do
    range = {property(request, "DTSTART"), property(request, "DTEND")}
    organiser = property(request, "ORGANIZER")

    responses =
      for attendee <- values(request, "ATTENDEE"),
          do: answer(attendee, organiser, range, options)

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(200, Schedule.schedule_response(responses))
  end

  defp answer(attendee, organiser, range, options) do
    case calendars_of(attendee, options) do
      [] ->
        {attendee, @invalid_user, nil}

      calendars ->
        {attendee, @success, busy(calendars, attendee, organiser, range, options)}
    end
  end

  # A recipient is addressed as `mailto:user@host`, and the store says
  # which collections belong to them. A store that cannot answer leaves
  # the recipient reported as unknown rather than silently free — being
  # told someone is free when they were never asked about is the one
  # answer a scheduler must not give.
  defp calendars_of(attendee, options) do
    case principal(attendee, options) do
      nil -> []
      home -> home |> children(options) |> Enum.filter(&Cal.calendar?/1)
    end
  end

  defp principal(attendee, %{store: store, context: context} = options) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(attendee, context) do
      home
    else
      _no_principal_lookup -> fallback(attendee, options)
    end
  end

  # Without a principal namespace, the only thing that can be said is
  # that this server does not know the address.
  defp fallback(_attendee, _options), do: nil

  defp children(resource, %{store: store, context: context}) do
    case store.children(resource, context) do
      {:ok, children} -> children
      _nothing -> []
    end
  end

  defp busy(calendars, attendee, organiser, range, options) do
    periods =
      calendars
      |> Enum.flat_map(&children(&1, options))
      |> Enum.reject(& &1.collection?)
      |> Enum.flat_map(&periods(&1, range, options))

    FreeBusy.vfreebusy(periods, range, attendee: attendee, organiser: organiser)
  end

  defp periods(object, range, %{store: store, context: context}) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(object, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(data)) do
      FreeBusy.periods_of(calendar, range)
    else
      _unreadable -> []
    end
  end

  defp property(component, name) do
    case Enum.find(component.properties, &(&1.name == name)) do
      nil -> nil
      found -> found.value
    end
  end

  defp values(component, name) do
    for property <- component.properties, property.name == name, do: property.value
  end
end
