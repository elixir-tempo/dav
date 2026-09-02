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
  alias Dav.Cal.Delegation
  alias Dav.Cal.FreeBusy
  alias Dav.Cal.ICalendar
  alias Dav.Cal.Schedule
  alias Dav.Cal.TimeRange
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  # The type the suite expects a stored calendar object to report,
  # parameter included: a client that asked for `charset=utf-8` on the
  # way in is entitled to see it on the way out.
  @calendar_type "text/calendar;charset=utf-8"

  # iTIP request statuses, RFC 5546 section 3.6.
  @success "2.0;Success"
  @invalid_user "3.7;Invalid calendar user"
  @no_inbox "5.1;Service unavailable"

  @free_busy_limit 30

  # The components an iTIP message can be about.
  @schedulable ~w(VFREEBUSY VEVENT VTODO VJOURNAL VPOLL)

  @impl Dav.Web.Method
  def call(conn, path, options) do
    with {:ok, resource} <- resolve(path, options),
         {:ok, kind} <- accepts(resource),
         :ok <- caller_allowed(kind, resource, options),
         {:ok, body, conn} <- request_body(conn, options),
         :ok <- media_type(conn),
         :ok <- readable(body),
         {:ok, calendar, component} <- scheduling_message(body),
         :ok <- unrestricted(calendar),
         :ok <- bounded_in_utc(component),
         {:ok, recipients} <- recipients(conn, component),
         :ok <- attendee_allowed(kind, calendar, component, resource, options),
         :ok <- organizer_allowed(kind, component, resource, options) do
      dispatch(kind, conn, calendar, component, recipients, options)
    else
      {:error, :not_found} ->
        send_resp(conn, 404, "")

      {:error, :not_outbox} ->
        send_resp(conn, 403, "")

      {:error, :forbidden} ->
        send_resp(conn, 403, "")

      {:error, {_namespace, _local} = failed} ->
        precondition(conn, failed)
    end
  end

  # An access restriction is a mark on a stored copy, not a thing a
  # scheduling message may carry: the recipients' servers each keep
  # their own users' privacy.
  defp unrestricted(calendar) do
    marked =
      Enum.find_value(calendar.properties, fn property ->
        property.name == "X-CALENDARSERVER-ACCESS" && property.value
      end) ||
        Enum.find_value(calendar.components, fn component ->
          component.name != "VTIMEZONE" &&
            Enum.find_value(component.properties, fn property ->
              property.name == "X-CALENDARSERVER-ACCESS" && property.value
            end)
        end)

    if marked,
      do: {:error, {"http://calendarserver.org/ns/", "no-access-restrictions"}},
      else: :ok
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

  # RFC 4791 section 9.9, applied to the iTIP request too: a
  # free-busy window is bounded by dates with UTC times. A floating or
  # all-day bound names no instant, and answering it would mean
  # picking a zone for the asker.
  defp bounded_in_utc(%{name: "VFREEBUSY"} = component) do
    stated =
      for property <- component.properties,
          property.name in ~w(DTSTART DTEND),
          do: property.value

    if Enum.all?(stated, &Regex.match?(~r/^\d{8}T\d{6}Z$/, &1)),
      do: :ok,
      else: {:error, caldav("valid-calendar-data")}
  end

  defp bounded_in_utc(_component), do: :ok

  defp media_type(conn) do
    type = conn |> get_req_header("content-type") |> List.first() || "text/calendar"

    if calendar_type?(type), do: :ok, else: {:error, caldav("supported-calendar-data")}
  end

  # The declared charset is utf-8, and bytes that are not UTF-8 are
  # not calendar data in it — decoding them as if they were stores
  # mojibake under another user's name.
  defp readable(body) do
    if String.valid?(body), do: :ok, else: {:error, caldav("valid-calendar-data")}
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
      not one_event?(calendar) -> {:error, caldav("valid-calendar-data")}
      not one_answer?(calendar, component) -> {:error, caldav("valid-calendar-data")}
      true -> {:ok, calendar, component}
    end
  end

  # RFC 5546 section 3.2: an iTIP message is about one event. Several
  # components may describe it — a recurrence and its overrides — but
  # they share a `UID`, and a message carrying two of them is two
  # messages in one envelope with no way to say which the recipients
  # are being asked about.
  defp one_event?(calendar) do
    calendar.components
    |> Enum.filter(&(&1.name in @schedulable))
    |> Enum.map(&property(&1, "UID"))
    |> Enum.uniq()
    |> length() <= 1
  end

  # "The REPLY method is used to respond to a request" — by one
  # attendee, for themselves. A reply naming several says nothing
  # about which of them answered.
  defp one_answer?(calendar, component) do
    property(calendar, "METHOD") != "REPLY" or length(values(component, "ATTENDEE")) == 1
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
  # The Outbox is its owner's mouth: only they, an administrator, or
  # a holder of their write-proxy grant speak through it.
  defp caller_allowed(:receiver, _outbox, _options), do: :ok

  defp caller_allowed(:outbox, outbox, %{store: store, context: context} = options) do
    with caller when is_binary(caller) <- Map.get(options, :principal),
         {:ok, %Resource{owner: owner}} when is_binary(owner) <-
           store.resolve(Enum.drop(outbox.path, -1), context),
         false <- Delegation.authorized_writer?(caller, owner, options) do
      {:error, caldav("organizer-allowed")}
    else
      _anonymous_deployment_or_permitted -> :ok
    end
  end

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

  # RFC 6638 section 4.1: the attendee a `REPLY` answers for must be
  # the owner of the Outbox it was posted to. Answering on somebody
  # else's behalf is how a scheduling system is abused, and the
  # organiser has no way to tell the difference from the message.
  defp attendee_allowed(:receiver, _calendar, _component, _outbox, _options), do: :ok

  defp attendee_allowed(:outbox, calendar, component, outbox, options) do
    if property(calendar, "METHOD") == "REPLY" do
      component |> values("ATTENDEE") |> List.first() |> answering(outbox, options)
    else
      :ok
    end
  end

  defp answering(attendee, outbox, options) do
    case principal(attendee, options) do
      %Resource{} = home ->
        if owns?(home, outbox), do: :ok, else: {:error, caldav("attendee-allowed")}

      nil ->
        {:error, caldav("attendee-allowed")}
    end
  end

  defp dispatch(kind, conn, calendar, component, recipients, options) do
    cond do
      component.name == "VFREEBUSY" and property(calendar, "METHOD") == "REQUEST" ->
        respond(conn, component, options)

      # RFC 6638 appendix A: on a server doing implicit scheduling,
      # the old explicit `POST` of an event message duplicates what
      # the PUT already did — a compatible client double-books every
      # attendee. The reference accepts the request, reports each
      # recipient as succeeding, and delivers nothing locally — a
      # recipient on another server is queued for iSchedule rather
      # than double-delivered here. Only the free-busy question above
      # is still the Outbox's to answer; the server-to-server receiver
      # is different, its messages arrive from elsewhere with no PUT
      # behind them.
      kind == :outbox ->
        responses = for recipient <- recipients, do: {recipient, @success, nil}

        conn
        |> put_resp_content_type("application/xml", "utf-8")
        |> send_resp(200, Schedule.schedule_response(responses))

      true ->
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
          nil ->
            {recipient, @invalid_user, nil}

          home ->
            {recipient, delivery_status(home, recipient, calendar, component, options), nil}
        end
      end

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(200, Schedule.schedule_response(responses))
  end

  defp delivery_status(home, recipient, calendar, component, options) do
    with %Resource{} = inbox <- inbox_of(home, options),
         :ok <- put_message(inbox, recipient, calendar, component, options) do
      @success
    else
      _undeliverable -> @no_inbox
    end
  end

  # A message in an Inbox records who sent it and who it was sent to.
  # The recipient's client reads them to tell an invitation addressed
  # to them apart from one delivered to a calendar they merely read,
  # which the message body does not say.
  defp addressed(resource, originator, recipient, store, context) do
    if is_binary(originator) and Store.supports?(store, :patch) do
      store.patch(
        resource,
        [
          {:set, {Xml.caldav(), "originator"}, {:hrefs, [originator]}},
          {:set, {Xml.caldav(), "recipient"}, {:hrefs, [recipient]}}
        ],
        context
      )
    end

    :ok
  end

  # An Inbox holds messages, not events. Two messages about one event
  # are two things to read, and writing both under the event's `UID`
  # leaves the recipient with only whichever arrived last.
  defp unused(inbox, name, store, context) do
    [name]
    |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{name}-#{&1}"))
    |> Enum.find_value(fn candidate ->
      path = inbox.path ++ ["#{candidate}.ics"]

      if match?({:error, :not_found}, store.resolve(path, context)), do: "#{candidate}.ics"
    end)
  end

  defp inbox_of(home, %{store: store, context: context}) do
    case store.children(home, context) do
      {:ok, children} -> Enum.find(children, &Schedule.inbox?/1)
      _nothing -> nil
    end
  end

  defp put_message(inbox, recipient, calendar, component, %{store: store, context: context}) do
    if Store.supports?(store, :put) do
      name = unused(inbox, property(component, "UID") || "message", store, context)
      body = wrap(calendar, component)

      case store.put(inbox.path ++ [name], body, @calendar_type, context) do
        {:ok, _outcome, resource} ->
          addressed(resource, property(component, "ORGANIZER"), recipient, store, context)

        _refused ->
          :error
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

    # The request's window is read once here. Below this, every
    # calendar scanned and every period clipped works in instants.
    window =
      case TimeRange.bounds(range) do
        {:ok, read} -> read
        :error -> {nil, nil}
      end

    options =
      options
      |> Map.put(:mask_uid, property(request, "X-CALENDARSERVER-MASK-UID"))
      |> Map.put(
        :extended_freebusy,
        property(request, "X-CALENDARSERVER-EXTENDED-FREEBUSY") == "T"
      )

    # The reference caps a free-busy request at thirty calendar users
    # including the organiser (`LimitFreeBusyAttendees`): expanding a
    # calendar per attendee is real work, and a runaway request would
    # do it hundreds of times. The overflow is answered `5.1` rather
    # than silently dropped.
    {asked, overflow} =
      request.properties
      |> Enum.filter(&(&1.name == "ATTENDEE"))
      |> Enum.split(@free_busy_limit - 1)

    responses =
      for(
        property <- asked,
        do: answer(property.value, property.parameters, organiser, {range, window}, options)
      ) ++ for property <- overflow, do: {property.value, @no_inbox, nil}

    conn
    |> put_resp_content_type("application/xml", "utf-8")
    |> send_resp(200, Schedule.schedule_response(responses))
  end

  # Read as the person being asked about, not as the person asking.
  # A shared calendar shows each of its readers something slightly
  # different — whether an event makes *them* busy is theirs to say —
  # so answering for someone else while scoped to the requester
  # reports the requester's own view of time that is not theirs.
  defp answer(attendee, parameters, organiser, asked, options) do
    options = as_attendee(attendee, options)

    case calendars_of(attendee, options) do
      [] ->
        # A recipient addressed by a local principal path refers to
        # something this server can name — a group, a disabled
        # account — and merely cannot be scheduled with. A `mailto:`
        # this server does not host names somebody on another server,
        # and the question goes out over iSchedule — reported as
        # succeeding, the way the reference queues it. Any other URI
        # that resolves to nobody does not exist.
        cond do
          String.starts_with?(attendee, "/") -> {attendee, @invalid_user, nil}
          remote?(attendee, organiser) -> {attendee, @success, nil}
          true -> {attendee, @invalid_user, nil, :missing}
        end

      calendars ->
        {attendee, @success,
         busy(calendars, {attendee, parameters}, organiser, asked, detailed(attendee, options))}
    end
  end

  # Apple's `X-CALENDARSERVER-EXTENDED-FREEBUSY`: the asker gets the
  # events themselves, not only the times — for the calendars they
  # could read anyway: their own, and those they hold a proxy grant
  # on. Anyone else's answer stays times alone.
  defp detailed(attendee, %{store: store, context: context} = options) do
    privileged? =
      own_home?(attendee, store, context, options) or
        readable_home?(attendee, store, context, options)

    include? =
      Map.get(options, :extended_freebusy, false) and
        (privileged? or public_schedule?(attendee, store, context))

    options
    |> Map.put(:detailed_freebusy, include?)
    |> Map.put(:freebusy_privileged, privileged?)
    |> Map.put(:freebusy_self, own_home?(attendee, store, context, options))
  end

  # A room or a projector has no privacy to keep: where it is booked
  # is exactly what anybody asking wants to know.
  defp public_schedule?(attendee, store, context) do
    Store.supports?(store, :unattended?) and store.unattended?(attendee, context)
  end

  defp readable_home?(attendee, store, context, options) do
    with true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{owner: owner}} when is_binary(owner) <-
           store.principal(attendee, context) do
      Delegation.authorized_reader?(Map.get(options, :principal), owner, options)
    else
      _unplaced -> false
    end
  end

  defp own_home?(attendee, store, context, options) do
    with caller when is_binary(caller) <- Map.get(options, :principal),
         true <- function_exported?(store, :principal, 2),
         {:ok, %Resource{owner: owner}} when is_binary(owner) <-
           store.principal(attendee, context),
         {:ok, %Resource{owner: caller_owner}} when is_binary(caller_owner) <-
           store.resolve(Store.segments(caller), context) do
      caller_owner == owner
    else
      _unplaced -> false
    end
  end

  # An address this server cannot resolve but another might: a
  # `mailto:` names a user by domain, and a domain this deployment
  # does not host is somebody else's to answer for. The organiser's
  # own domain is the one domain known to be served here, so an
  # unresolvable user *there* is nobody, not a neighbour.
  defp remote?(attendee, organiser) do
    case {mail_domain(attendee), mail_domain(organiser)} do
      {[_, theirs], [_, ours]} -> String.downcase(theirs) != String.downcase(ours)
      {[_, _theirs], _not_mailto} -> true
      {_not_a_mailbox, _organiser} -> false
    end
  end

  defp mail_domain(address) when is_binary(address) do
    with true <- String.match?(address, ~r/^mailto:/i),
         [user, domain] <- address |> String.slice(7..-1//1) |> String.split("@", parts: 2) do
      [user, domain]
    else
      _not_a_mailbox -> nil
    end
  end

  defp mail_domain(_address), do: nil

  defp as_attendee(attendee, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :scope),
         %Resource{owner: owner} when is_binary(owner) <- principal(attendee, options) do
      %{options | context: store.scope(context, owner)}
    else
      _unknown -> options
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
      home -> selected_calendars(home, options)
    end
  end

  # RFC 4791 section 6.2.1: an Inbox carrying
  # `CALDAV:calendar-free-busy-set` names exactly the calendars the
  # owner's free-busy consults — wherever they sit in the home. With
  # nothing stated, every opaque calendar directly in the home is.
  defp selected_calendars(home, %{store: store, context: context} = options) do
    case free_busy_selection(home, options) do
      nil ->
        home
        |> children(options)
        |> Enum.filter(&Cal.calendar?/1)
        |> Enum.reject(&FreeBusy.transparent?(&1, options))

      hrefs ->
        for href <- hrefs,
            {:ok, %Resource{} = calendar} <- [store.resolve(Store.segments(href), context)],
            do: calendar
    end
  end

  defp free_busy_selection(home, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :properties),
         %Resource{} = inbox <- Enum.find(children(home, options), &Schedule.inbox?/1),
         %{} = properties <- store.properties(inbox, context),
         {:hrefs, hrefs} <- Map.get(properties, {Xml.caldav(), "calendar-free-busy-set"}) do
      hrefs
    else
      _unstated -> nil
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

  defp busy(calendars, {address, _parameters} = attendee, organiser, {range, window}, options) do
    {periods, events} =
      calendars
      |> Enum.flat_map(fn calendar ->
        borrowed = borrowed?(calendar, options)

        calendar
        |> children(options)
        |> Enum.reject(&(&1.collection? or Delegation.busy_excluded?(&1, options)))
        |> Enum.map(&periods(&1, window, borrowed, address, organiser, options))
      end)
      |> Enum.reduce({[], []}, fn {periods, events}, {all_periods, all_events} ->
        {all_periods ++ periods, all_events ++ events}
      end)

    FreeBusy.vfreebusy(periods, range,
      attendee: attendee,
      organizer: organiser,
      method: "REPLY",
      events: events
    )
  end

  defp periods(
         object,
         window,
         borrowed?,
         address,
         organiser,
         %{store: store, context: context} = options
       ) do
    with true <- Store.supports?(store, :read),
         {:ok, data} <- store.read(object, context),
         {:ok, calendar} <- ICalendar.parse(IO.iodata_to_binary(data)) do
      components =
        calendar.components
        |> kept(borrowed?)
        |> unmasked(address, organiser, options)

      trimmed = %{calendar | components: components}
      level = Dav.Cal.Access.level(object, options)

      {FreeBusy.periods_of(trimmed, window), shown(trimmed, level, window, options)}
    else
      _unreadable -> {[], []}
    end
  end

  # The events an extended answer shows: the ones whose time actually
  # lands in the window, alarms left out — they are the owner's, not
  # the asker's business.
  defp shown(calendar, level, window, options) do
    if Map.get(options, :detailed_freebusy, false) do
      for component <- calendar.components,
          component.name == "VEVENT",
          not hidden?(calendar, component, level, options),
          FreeBusy.periods_of(%{calendar | components: [component]}, window) != [],
          do: presentable(component, options)
    else
      []
    end
  end

  # A private event's *time* is busy like any other; the event itself
  # shows only to its own calendar's owner. The access mark may be
  # held beside the stored copy, or sit in the body on the calendar or
  # the component — clients write both.
  defp hidden?(calendar, component, level, options) do
    stated =
      level ||
        property(component, "X-CALENDARSERVER-ACCESS") ||
        property(calendar, "X-CALENDARSERVER-ACCESS")

    stated in ~w(PRIVATE CONFIDENTIAL RESTRICTED) and
      not Map.get(options, :freebusy_self, false)
  end

  # A room's schedule is public, but the bookings on it are only
  # public in outline: when it is, who booked it, and nothing more.
  # An asker holding a grant on the scanned calendar — its owner, an
  # administrator, a proxy — sees the events whole.
  @outline ~w(UID DTSTART DTEND DURATION DTSTAMP RECURRENCE-ID RRULE RDATE EXDATE
              TRANSP ORGANIZER ATTENDEE)

  defp presentable(component, options) do
    properties =
      if Map.get(options, :freebusy_privileged, false),
        do: component.properties,
        else: Enum.filter(component.properties, &(&1.name in @outline))

    %{
      component
      | properties: properties,
        components: Enum.reject(component.components, &(&1.name == "VALARM"))
    }
  end

  # Apple's `X-CALENDARSERVER-MASK-UID`: the event being rescheduled
  # is left out of the report, so it does not read as a conflict with
  # itself. Only the asker's own meeting hides — the event's organizer
  # must be the request's, or, for an event with no organizer at all,
  # the calendar it sits in must be the request organizer's own.
  defp unmasked(components, address, organiser, %{mask_uid: mask} = options)
       when is_binary(mask) do
    Enum.reject(components, fn component ->
      component.name != "VTIMEZONE" and property(component, "UID") == mask and
        hidden_from?(component, address, organiser, options)
    end)
  end

  defp unmasked(components, _address, _organiser, _options), do: components

  defp hidden_from?(component, address, organiser, options) do
    case property(component, "ORGANIZER") do
      nil -> same_user?(address, organiser, options)
      owner -> same_user?(owner, organiser, options)
    end
  end

  defp same_user?(one, other, options) when is_binary(one) and is_binary(other),
    do: canonical_spelling(one, options) == canonical_spelling(other, options)

  defp same_user?(one, other, _options), do: one == other

  defp canonical_spelling(address, %{store: store, context: context}) do
    with true <- Store.supports?(store, :canonical_address),
         {:ok, spelled} <- store.canonical_address(address, context) do
      String.downcase(spelled)
    else
      _unknown -> String.downcase(address)
    end
  end

  # An all-day event in somebody else's calendar does not make you
  # busy. It is on the day, not at a time: being shown a colleague's
  # holiday says where they are, not that a meeting cannot be booked
  # with you. Saying so for yourself is different — a sharee who
  # writes their own `TRANSP` has decided, and their decision stands.
  defp kept(components, false), do: components
  defp kept(components, true), do: Enum.reject(components, &undecided_all_day?/1)

  defp undecided_all_day?(component) do
    all_day?(component) and
      not Enum.any?(component.properties, &(&1.name == "TRANSP"))
  end

  defp all_day?(component) do
    case Enum.find(component.properties, &(&1.name == "DTSTART")) do
      nil -> false
      property -> Map.get(property.parameters, "VALUE") == "DATE"
    end
  end

  @shared_url {"http://calendarserver.org/ns/", "shared-url"}

  # A calendar that records where it points at is a share link, and
  # what it shows belongs to somebody else.
  defp borrowed?(collection, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(collection, context) do
      Map.has_key?(properties, @shared_url)
    else
      _no_properties -> false
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
