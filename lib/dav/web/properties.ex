defmodule Dav.Web.Properties do
  @moduledoc """
  The live properties a server computes for a resource.

  *Live* properties are the server's own account of a resource — its
  size, its type, when it changed. *Dead* properties are values a
  client stored with `PROPPATCH` and expects back unaltered, and they
  belong to a store rather than here.

  RFC 4918 section 15 defines the set. Two are load-bearing and worth
  naming:

  * `DAV:resourcetype` is how a client tells a collection from an
    ordinary resource, and getting it wrong makes a calendar look like
    a file.

  * `DAV:getetag` is what synchronisation is built on. An ETag that
    fails to change when the resource does causes silent data loss,
    and the client gets blamed for it.

  """

  alias Dav.Web.Acl
  alias Dav.Web.Resource
  alias Dav.Xml

  # The properties this server computes, and therefore owns. Being
  # protected is a fact about the *name*, not about whether a given
  # resource happens to have a value for it — a resource with no ETag
  # still must not let a client invent one.
  @live ~w(resourcetype displayname getetag getcontentlength getcontenttype
           getlastmodified creationdate supported-report-set)

  # `displayname` is live in the sense that the server computes a
  # default, but RFC 4918 section 15.2 says it "SHOULD NOT be
  # protected" — a client is entitled to name a collection, through
  # PROPPATCH or in a MKCALENDAR body. Treating it as protected refuses
  # both, and returns the path segment however the user renamed it.
  @protected @live -- ["displayname"]

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Every live property this server can report for a resource.

  Properties with no value are omitted rather than reported empty: a
  resource with no ETag does not have an empty ETag.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  ### Returns

  * A list of `{qname, value}` pairs, ready for
    `Dav.Xml.multistatus/1`.

  ### Examples

      iex> resource = %Dav.Web.Resource{path: ["c"], collection?: true, display_name: "Calendars"}
      iex> Dav.Web.Properties.all(resource) |> Enum.map(fn {{_ns, name}, _value} -> name end)
      ["resourcetype", "displayname"]

  """
  @spec all(Resource.t()) :: [{Xml.qname(), Xml.value()}]
  def all(%Resource{} = resource) do
    for name <- @live -- ["supported-report-set"],
        {:ok, value} <- [fetch(resource, {Xml.dav(), name})] do
      {{Xml.dav(), name}, value}
    end
  end

  @doc """
  One live property, by qualified name.

  ### Arguments

  * `resource` is a `t:Dav.Web.Resource.t/0`.

  * `qname` is the `{namespace, local}` name asked for.

  ### Returns

  * `{:ok, value}` when this server can report it; or

  * `:error` when it cannot, which is what a `404` propstat is made
    of.

  ### Examples

      iex> resource = %Dav.Web.Resource{path: ["c"], collection?: true}
      iex> Dav.Web.Properties.fetch(resource, {"DAV:", "resourcetype"})
      {:ok, {:names, [{"DAV:", "collection"}]}}

      iex> resource = %Dav.Web.Resource{path: ["c", "1.ics"], etag: ~s("abc")}
      iex> Dav.Web.Properties.fetch(resource, {"DAV:", "getetag"})
      {:ok, ~s("abc")}

      iex> Dav.Web.Properties.fetch(%Dav.Web.Resource{}, {"DAV:", "invented"})
      :error

  """
  @spec fetch(Resource.t(), Xml.qname()) :: {:ok, Xml.value()} | :error
  # `CALDAV:schedule-calendar-transp` is deliberately *not* computed
  # here. It is a calendar's property, and this module knows nothing
  # about calendars — a deployment sets it on the collection, where it
  # is stored and reported like any other. Reaching into `Dav.Cal` for
  # it would put the base's knowledge of CalDAV back exactly where the
  # seams were built to remove it.

  # Deprecated by RFC 6638 in favour of `schedule-calendar-transp`. It
  # is named here only to mark it protected: a server that still
  # reports it must not let it be written, and that is a fact about
  # the name rather than about calendars.
  def fetch(%Resource{}, {"urn:ietf:params:xml:ns:caldav", "calendar-free-busy-set"}),
    do: {:ok, nil}

  # Access control, RFC 3744. These are computed rather than stored:
  # they describe a policy, and a server with no authentication has one
  # policy. What matters to a client is that they are *present* — a
  # calendar that cannot read `DAV:current-user-privilege-set` has to
  # assume it may write, and discovers otherwise by failing.
  def fetch(%Resource{}, {"DAV:", "supported-privilege-set"}),
    do: {:ok, Acl.supported_privilege_set()}

  def fetch(%Resource{}, {"DAV:", "current-user-privilege-set"}),
    do: {:ok, Acl.current_user_privilege_set()}

  def fetch(%Resource{}, {"DAV:", "acl-restrictions"}), do: {:ok, Acl.acl_restrictions()}

  def fetch(%Resource{owner: nil}, {"DAV:", "acl"}), do: :error
  def fetch(%Resource{owner: owner}, {"DAV:", "acl"}), do: {:ok, Acl.acl(owner)}

  def fetch(%Resource{owner: nil}, {"DAV:", "owner"}), do: :error
  def fetch(%Resource{owner: owner}, {"DAV:", "owner"}), do: {:ok, {:hrefs, [owner]}}

  # "This protected property, if present, contains the URL of the
  # principal that is the group of the resource." No groups here.
  def fetch(%Resource{}, {"DAV:", "group"}), do: {:ok, nil}

  def fetch(%Resource{}, {"DAV:", "inherited-acl-set"}), do: {:ok, nil}

  # RFC 5397's `DAV:current-user-principal` is *not* here. It answers
  # "who am I", which is a fact about the request rather than about
  # the resource being described — the same resource returns different
  # values to different callers. `Dav.Web.Plug` supplies it from the
  # authenticated principal; deriving it from the resource's owner
  # instead tells every caller they are the owner.

  def fetch(%Resource{owner: nil}, {"DAV:", "principal-URL"}), do: :error

  def fetch(%Resource{} = resource, {"DAV:", "principal-URL"}) do
    if Acl.principal?(resource), do: {:ok, {:hrefs, [Resource.href(resource)]}}, else: :error
  end

  def fetch(%Resource{collection?: true} = resource, {"DAV:", "resourcetype"}) do
    {:ok, {:names, [{Xml.dav(), "collection"} | resource.types]}}
  end

  def fetch(%Resource{types: []}, {"DAV:", "resourcetype"}), do: {:ok, nil}
  def fetch(%Resource{types: types}, {"DAV:", "resourcetype"}), do: {:ok, {:names, types}}

  def fetch(%Resource{} = resource, {"DAV:", "displayname"}) do
    case resource.display_name || Resource.name(resource) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  def fetch(%Resource{etag: nil}, {"DAV:", "getetag"}), do: :error
  def fetch(%Resource{etag: etag}, {"DAV:", "getetag"}), do: {:ok, etag}

  # A collection has no length or type of its own. Reporting zero
  # would be a claim about a body it does not have.
  # A collection returns nothing on GET, so its content has no length —
  # but clients ask for this property on collections constantly, and
  # answering `404` for it makes a routine PROPFIND look half-failed.
  # Zero is what a collection's body actually weighs.
  def fetch(%Resource{collection?: true}, {"DAV:", "getcontentlength"}), do: {:ok, "0"}
  def fetch(%Resource{content_length: nil}, {"DAV:", "getcontentlength"}), do: :error

  def fetch(%Resource{content_length: length}, {"DAV:", "getcontentlength"}) do
    {:ok, Integer.to_string(length)}
  end

  def fetch(%Resource{collection?: true}, {"DAV:", "getcontenttype"}), do: :error
  def fetch(%Resource{content_type: nil}, {"DAV:", "getcontenttype"}), do: :error
  def fetch(%Resource{content_type: type}, {"DAV:", "getcontenttype"}), do: {:ok, type}

  def fetch(%Resource{modified_at: nil}, {"DAV:", "getlastmodified"}), do: :error

  def fetch(%Resource{modified_at: at}, {"DAV:", "getlastmodified"}) do
    {:ok, http_date(at)}
  end

  def fetch(%Resource{modified_at: nil}, {"DAV:", "creationdate"}), do: :error

  def fetch(%Resource{modified_at: at}, {"DAV:", "creationdate"}) do
    {:ok, at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()}
  end

  def fetch(%Resource{}, {_namespace, _local}), do: :error

  @doc """
  Format a moment as an HTTP-date.

  `DAV:getlastmodified` is an HTTP-date, not ISO 8601 — RFC 4918 is
  explicit about it, and a client comparing against an `If-Modified-Since`
  will not recognise anything else. The names are always English
  regardless of locale, which is why they are spelled out here rather
  than left to a formatter.

  ### Arguments

  * `datetime` is a `t:DateTime.t/0`.

  ### Returns

  * The moment in UTC, as `"Tue, 15 Nov 1994 12:45:26 GMT"`.

  ### Examples

      iex> Dav.Web.Properties.http_date(~U[1994-11-15 12:45:26Z])
      "Tue, 15 Nov 1994 12:45:26 GMT"

  """
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = datetime) do
    at = DateTime.shift_zone!(datetime, "Etc/UTC")
    day = Enum.at(@days, Date.day_of_week(at) - 1)
    month = Enum.at(@months, at.month - 1)

    pad = fn value -> value |> Integer.to_string() |> String.pad_leading(2, "0") end

    "#{day}, #{pad.(at.day)} #{month} #{at.year} " <>
      "#{pad.(at.hour)}:#{pad.(at.minute)}:#{pad.(at.second)} GMT"
  end

  @doc """
  Whether a property is the server's to compute rather than a client's
  to set.

  `PROPPATCH` on one of these is `403`, and RFC 4918 asks for the
  `cannot-modify-protected-property` precondition rather than silent
  acceptance — a client that believes it set an ETag will behave
  incorrectly later.

  `DAV:displayname` is treated as protected here, which is stricter
  than the specification requires: it says displayname SHOULD be
  settable. Revisit when a store wants to own it.

  ### Arguments

  * `qname` is the property's `{namespace, local}` name.

  ### Returns

  * `true` when the server owns the property.

  ### Examples

      iex> Dav.Web.Properties.protected?({"DAV:", "getetag"})
      true

      iex> Dav.Web.Properties.protected?({"http://example.test/", "colour"})
      false

  """
  @spec protected?(Xml.qname()) :: boolean()
  def protected?({"DAV:", local}), do: local in @protected

  # RFC 6638 deprecated `calendar-free-busy-set`; a server that still
  # reports it must not let it be written.
  def protected?({"urn:ietf:params:xml:ns:caldav", "calendar-free-busy-set"}), do: true
  def protected?({_namespace, _local}), do: false
end
