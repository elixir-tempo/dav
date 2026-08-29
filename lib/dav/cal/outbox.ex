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
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  # iTIP request statuses, RFC 5546 section 3.6.
  @success "2.0;Success"
  @invalid_user "3.7;Invalid calendar user"
  @no_inbox "5.1;Service unavailable"

  # The components an iTIP message can be about.
  @schedulable ~w(VFREEBUSY VEVENT VTODO VJOURNAL VPOLL)

  @impl Dav.Web.Method
  def call(conn, path, options) do
    with {:ok, resource} <- resolve(path, options),
         {:ok, kind} <- accepts(resource),
         {:ok, body, conn} <- request_body(conn, options),
         :ok <- media_type(conn),
         {:ok, calendar, component} <- scheduling_message(body),
         {:ok, recipients} <- recipients(conn, component),
         :ok <- organizer_allowed(kind, component, resource, options) do
      dispatch(conn, calendar, component, recipients, options)
    else
      {:error, :not_found} -> send_resp(conn, 404, "")
      {:error, :not_outbox} -> send_resp(conn, 403, "")
      {:error, {_namespace, _local} = failed} -> precondition(conn, failed)
    end
  end

  # RFC 6638 section 5.2 gives this method its own preconditions, and
  # naming them is the whole value: a bare `400` tells a client its
  # request was wrong, while `CALDAV:organizer-allowed` tells it the
  # ORGANIZER was not one it may act for.
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

  # A dispatcher that had to read the body to route on passes it
  # along; anything else reads it here.
  defp request_body(conn, %{body: body}), do: {:ok, body, conn}
  defp request_body(conn, _options), do: read_body(conn)

  defp resolve(path, %{store: store, context: context}) do
    store.resolve(path, context)
  end

  # "The resource identified by the Request-URI MUST be a resource
  # collection of type CALDAV:schedule-outbox" — or an iSchedule
  # receiver, which takes the same messages from another server.
  defp accepts(resource) do
    cond do
      Schedule.outbox?(resource) -> {:ok, :outbox}
      Schedule.receiver?(resource) -> {:ok, :receiver}
      true -> {:error, :not_outbox}
    end
  end

  # An iTIP message: valid iCalendar, carrying a METHOD, with one
  # component the method applies to. Each failure is a different
  # precondition because each is a different mistake — data that is
  # not iCalendar, and iCalendar that is not a scheduling message,
  # need different corrections.
  defp scheduling_message(body) do
    case ICalendar.parse(body) do
      {:ok, %{name: "VCALENDAR"} = calendar} -> component_of(calendar)
      _unreadable -> {:error, caldav("valid-calendar-data")}
    end
  end

  defp component_of(calendar) do
    component = Enum.find(calendar.components, &(&1.name in @schedulable))

    cond do
      is_nil(property(calendar, "METHOD")) -> {:error, caldav("valid-calendar-data")}
      is_nil(component) -> {:error, caldav("valid-scheduling-message")}
      is_nil(property(component, "ORGANIZER")) -> {:error, caldav("valid-organizer")}
      true -> {:ok, calendar, component}
    end
  end

  # Recipients come from the `Recipient` header when the client sent
  # one, and otherwise from the message's own ATTENDEEs. A message
  # addressed to nobody is not a scheduling message.
  defp recipients(conn, component) do
    case header_recipients(conn) ++ values(component, "ATTENDEE") do
      [] -> {:error, caldav("recipient-specified")}
      found -> {:ok, Enum.uniq(found)}
    end
  end

  defp header_recipients(conn) do
    conn
    |> get_req_header("recipient")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # "The ORGANIZER property value MUST match one of the calendar user
  # addresses of the owner of the Outbox collection." Posting on
  # someone else's behalf is how a scheduling system is abused, so the
  # check is on identity rather than on the message.
  # A message arriving from another server names an organiser on that
  # server by definition, so there is nothing here to check it against.
  # Applying the Outbox rule would refuse every incoming invitation.
  defp organizer_allowed(:receiver, _component, _resource, _options), do: :ok

  defp organizer_allowed(:outbox, component, outbox, options) do
    organizer = property(component, "ORGANIZER")

    case principal(organizer, options) do
      nil -> {:error, caldav("organizer-allowed")}
      home -> if owns?(home, outbox), do: :ok, else: {:error, caldav("organizer-allowed")}
    end
  end

  # The Outbox sits inside its owner's collection home.
  defp owns?(%Resource{path: home}, %Resource{path: outbox}),
    do: Enum.take(outbox, length(home)) == home

  defp dispatch(conn, calendar, component, recipients, options) do
    if component.name == "VFREEBUSY" and property(calendar, "METHOD") == "REQUEST" do
      respond(conn, component, options)
    else
      deliver(conn, calendar, component, recipients, options)
    end
  end

  # Any other iTIP method is a message for the recipients rather than a
  # question for the server: it is placed in each recipient's Inbox,
  # which is what makes an invitation appear in someone's calendar.
  defp deliver(conn, calendar, component, recipients, options) do
    responses =
      for recipient <- recipients do
        case principal(recipient, options) do
          nil -> {recipient, @invalid_user, nil}
          home -> {recipient, delivery_status(home, calendar, component, options), nil}
        end
      end

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(200, Schedule.schedule_response(responses))
  end

  defp delivery_status(home, calendar, component, options) do
    with %Resource{} = inbox <- inbox_of(home, options),
         :ok <- put_message(inbox, calendar, component, options) do
      @success
    else
      _undeliverable -> @no_inbox
    end
  end

  defp inbox_of(home, %{store: store, context: context}) do
    case store.children(home, context) do
      {:ok, children} -> Enum.find(children, &Schedule.inbox?/1)
      _nothing -> nil
    end
  end

  defp put_message(inbox, calendar, component, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      name = (property(component, "UID") || "message") <> ".ics"
      body = wrap(calendar, component)

      case store.put(inbox.path ++ [name], body, "text/calendar", context) do
        {:ok, _outcome, _resource} -> :ok
        _refused -> :error
      end
    else
      :error
    end
  end

  # A scheduling Inbox holds *messages*, not ordinary calendar objects,
  # and a message keeps its METHOD: that is what says whether it is an
  # invitation, a reply or a cancellation. RFC 4791 section 4.1's ban
  # on METHOD is about calendar collections, and an Inbox is not one.
  # Stripping it here left every delivered invitation indistinguishable
  # from a cancellation.
  defp wrap(calendar, component) do
    method = property(calendar, "METHOD")

    message = %{
      name: "VCALENDAR",
      properties: version() ++ method_property(method),
      components: [component]
    }

    ICalendar.write(message)
  end

  defp version do
    [
      %{name: "VERSION", parameters: %{}, value: "2.0"},
      %{name: "PRODID", parameters: %{}, value: "-//Dav//CalDAV//EN"}
    ]
  end

  defp method_property(nil), do: []
  defp method_property(method), do: [%{name: "METHOD", parameters: %{}, value: method}]

  # The busy-time question, answered from the calendars this server
  # holds. Shared with `Dav.Cal.FreeBusy` so that a request over the
  # Outbox and the `free-busy-query` report give the same answer.
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
      [] -> {attendee, @invalid_user, nil}
      calendars -> {attendee, @success, busy(calendars, attendee, organiser, range, options)}
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

  defp principal(address, %{store: store, context: context}) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, home} <- store.principal(address, context) do
      home
    else
      _no_principal_lookup -> nil
    end
  end

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

    FreeBusy.vfreebusy(periods, range, attendee: attendee, organizer: organiser)
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
