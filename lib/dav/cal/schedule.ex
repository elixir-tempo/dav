defmodule Dav.Cal.Schedule do
  @moduledoc """
  CalDAV scheduling — RFC 6638.

  Scheduling is what turns a calendar server into a way for people to
  arrange things with each other: an organiser writes one event naming
  attendees, and the server delivers it to their calendars, collects
  their replies, and answers questions about when they are free.

  RFC 6638 is Standards Track and **updates RFC 4791** — it is not an
  optional extra on top of CalDAV, and a server without it cannot do
  the one thing calendar users most want.

  ### The two collections

  Each principal has a scheduling **Outbox**, the target for busy-time
  requests, and a scheduling **Inbox**, where messages addressed to
  them arrive. Both are ordinary WebDAV collections distinguished by
  their resource type, exactly as a calendar collection is:

      <D:resourcetype xmlns:D="DAV:">
        <D:collection/>
        <C:schedule-outbox xmlns:C="urn:ietf:params:xml:ns:caldav"/>
      </D:resourcetype>

  Neither may be a child of a calendar collection, at any depth.

  ### Finding them

  A client locates them through properties on the principal —
  `CALDAV:schedule-inbox-URL` and `CALDAV:schedule-outbox-URL` — and
  learns which addresses identify a person through
  `CALDAV:calendar-user-address-set`. Those addresses are how an
  `ATTENDEE:mailto:…` in an event is matched to a principal on this
  server.

  """

  alias Dav.Cal.ICalendar
  alias Dav.Cal.JCal
  alias Dav.Web.Resource
  alias Dav.Xml

  @doc """
  The resource type a scheduling Outbox must report.

  ### Returns

  * The `CALDAV:schedule-outbox` qualified name.

  ### Examples

      iex> Dav.Cal.Schedule.outbox()
      {"urn:ietf:params:xml:ns:caldav", "schedule-outbox"}

  """
  @spec outbox() :: Xml.qname()
  def outbox, do: {Xml.caldav(), "schedule-outbox"}

  @doc """
  The resource type a scheduling Inbox must report.

  ### Returns

  * The `CALDAV:schedule-inbox` qualified name.

  ### Examples

      iex> Dav.Cal.Schedule.inbox()
      {"urn:ietf:params:xml:ns:caldav", "schedule-inbox"}

  """
  @spec inbox() :: Xml.qname()
  def inbox, do: {Xml.caldav(), "schedule-inbox"}

  @doc """
  Whether a resource is a scheduling Outbox.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports `CALDAV:schedule-outbox`.

  ### Examples

      iex> Dav.Cal.Schedule.outbox?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.Schedule.outbox()]})
      true

      iex> Dav.Cal.Schedule.outbox?(%Dav.Web.Resource{collection?: true})
      false

  """
  @spec outbox?(Resource.t()) :: boolean()
  def outbox?(%Resource{types: types}), do: outbox() in types

  @doc """
  Whether a resource is a scheduling Inbox.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports `CALDAV:schedule-inbox`.

  ### Examples

      iex> Dav.Cal.Schedule.inbox?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.Schedule.inbox()]})
      true

  """
  @spec inbox?(Resource.t()) :: boolean()
  def inbox?(%Resource{types: types}), do: inbox() in types

  @doc """
  The resource type of an iSchedule receiver.

  iSchedule is scheduling *between* servers: an organiser on one
  server invites an attendee on another, and the message arrives at
  the receiving server's endpoint rather than at any one user's
  Outbox. The draft is not an RFC, and the type is named here so that
  a deployment can mark the endpoint explicitly rather than the server
  guessing from a path.

  ### Returns

  * The receiver's qualified name.

  ### Examples

      iex> Dav.Cal.Schedule.receiver()
      {"urn:ietf:params:xml:ns:ischedule", "receiver"}

  """
  @spec receiver() :: Xml.qname()
  def receiver, do: {"urn:ietf:params:xml:ns:ischedule", "receiver"}

  @doc """
  Whether a resource is an iSchedule receiver.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports the receiver type.

  ### Examples

      iex> Dav.Cal.Schedule.receiver?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.Schedule.receiver()]})
      true

  """
  @spec receiver?(Resource.t()) :: boolean()
  def receiver?(%Resource{types: types}), do: receiver() in types

  @doc """
  Build a `CALDAV:schedule-response` document.

  The answer to a `POST` on a scheduling Outbox. One `CALDAV:response`
  per recipient, each carrying the recipient's address, an iTIP
  request status, and — for a busy-time request — that recipient's
  `VFREEBUSY`.

  Returning a status *per recipient* rather than one for the whole
  request is the point: asking about five people and being told
  "failed" says nothing about which four were answerable.

  ### Arguments

  * `responses` is a list of `{recipient, request_status, calendar_data}`
    tuples. `calendar_data` may be `nil`.

  ### Returns

  * The document as iodata.

  ### Examples

      iex> Dav.Cal.Schedule.schedule_response([{"mailto:a@example.com", "2.0;Success", nil}])
      ...> |> IO.iodata_to_binary()
      ...> |> String.contains?("<recipient><D:href>mailto:a@example.com</D:href></recipient>")
      true

  """
  @spec schedule_response([{String.t(), String.t(), binary() | nil}]) :: [iodata()]
  # Serialised in the CalDAV *default* namespace, the way the
  # reference emits it: unprefixed elements with one `xmlns` on the
  # root. Prefixes would be equivalent XML, but clients (and the
  # conformance suite) match these responses textually.
  def schedule_response(responses, syntax \\ :icalendar) do
    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      ~s(<schedule-response xmlns:D="DAV:" xmlns="),
      Xml.caldav(),
      ~s(">),
      Enum.map(responses, &response(&1, syntax)),
      "</schedule-response>"
    ]
  end

  # RFC 6638 section 8.2: a recipient the server cannot find at all
  # fails the `CALDAV:recipient-exists` check, and the response names
  # the failed precondition alongside the `3.7` status — so a client
  # can tell "no such user" from a user who exists but cannot be
  # scheduled with.
  defp response({recipient, status, data, :missing}, syntax) do
    failed = ["<D:error><recipient-exists xmlns='", Xml.caldav(), "'/></D:error>"]
    response({recipient, status, data}, syntax, failed)
  end

  defp response({recipient, status, data}, syntax),
    do: response({recipient, status, data}, syntax, [])

  defp response({recipient, status, data}, syntax, failed) do
    [
      "<response>",
      "<recipient><D:href>",
      escape(recipient),
      "</D:href></recipient>",
      "<request-status>",
      escape(status),
      "</request-status>",
      calendar_data(data, syntax),
      failed,
      "</response>"
    ]
  end

  defp calendar_data(nil, _syntax), do: []

  defp calendar_data(data, :icalendar),
    do: ["<calendar-data>", escape(IO.iodata_to_binary(data)), "</calendar-data>"]

  # A busy-time answer is written in the syntax the question was asked
  # in, and says which one that is: the `content-type` attribute is
  # the only thing telling a client whether to reach for its iCalendar
  # parser or its JSON one.
  defp calendar_data(data, :jcal) do
    case data |> IO.iodata_to_binary() |> ICalendar.parse() do
      {:ok, component} ->
        [
          ~s(<calendar-data content-type="),
          JCal.content_type(),
          ~s(">),
          escape(JCal.encode(component)),
          "</calendar-data>"
        ]

      _unreadable ->
        calendar_data(data, :icalendar)
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
