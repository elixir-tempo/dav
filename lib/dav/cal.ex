defmodule Dav.Cal do
  @moduledoc """
  CalDAV — RFC 4791.

  Calendars over WebDAV. A calendar collection is an ordinary WebDAV
  collection that additionally reports `CALDAV:calendar` in its
  resource type, and the calendar objects inside it are ordinary
  resources whose bodies are iCalendar.

  Everything here reaches `Dav.Web` through the two seams it offers
  rather than by modifying it: `MKCALENDAR` is a `Dav.Web.Method`, and
  the queries are `Dav.Web.Report`s. That is the whole reason those
  seams exist, and why all three protocols live in one package without
  the base knowing what a calendar is.

      forward "/dav", to: Dav.Web.Plug,
        init_opts: [
          store: MyStore,
          methods: [{"MKCALENDAR", Dav.Cal.Mkcalendar}]
        ]

  """

  alias Dav.Xml

  @doc """
  The resource type a calendar collection must report.

  RFC 4791 section 4.2: *"A calendar collection MUST report the
  DAV:collection and CALDAV:calendar XML elements in the value of the
  DAV:resourcetype property."* Setting this in a resource's `types`
  is what makes it a calendar as far as a client is concerned.

  ### Returns

  * The `CALDAV:calendar` qualified name.

  ### Examples

      iex> Dav.Cal.calendar()
      {"urn:ietf:params:xml:ns:caldav", "calendar"}

      iex> %Dav.Web.Resource{path: ["c"], collection?: true, types: [Dav.Cal.calendar()]}
      ...> |> Dav.Web.Properties.fetch({"DAV:", "resourcetype"})
      {:ok, {:names, [{"DAV:", "collection"}, {"urn:ietf:params:xml:ns:caldav", "calendar"}]}}

  """
  @spec calendar() :: Xml.qname()
  def calendar, do: {Xml.caldav(), "calendar"}

  @doc """
  Whether a resource is a calendar collection.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * `true` when it reports `CALDAV:calendar`.

  ### Examples

      iex> Dav.Cal.calendar?(%Dav.Web.Resource{collection?: true, types: [Dav.Cal.calendar()]})
      true

      iex> Dav.Cal.calendar?(%Dav.Web.Resource{collection?: true})
      false

  """
  @spec calendar?(Dav.Web.Resource.t()) :: boolean()
  def calendar?(%Dav.Web.Resource{types: types}), do: calendar() in types
end
