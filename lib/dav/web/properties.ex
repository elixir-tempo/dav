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

  alias Dav.Web.Resource
  alias Dav.Xml

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
    for name <- ~w(resourcetype displayname getetag getcontentlength getcontenttype
                   getlastmodified creationdate),
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
      {:ok, {:elements, "<D:collection/>"}}

      iex> resource = %Dav.Web.Resource{path: ["c", "1.ics"], etag: ~s("abc")}
      iex> Dav.Web.Properties.fetch(resource, {"DAV:", "getetag"})
      {:ok, ~s("abc")}

      iex> Dav.Web.Properties.fetch(%Dav.Web.Resource{}, {"DAV:", "invented"})
      :error

  """
  @spec fetch(Resource.t(), Xml.qname()) :: {:ok, Xml.value()} | :error
  def fetch(%Resource{collection?: true}, {"DAV:", "resourcetype"}) do
    {:ok, {:elements, "<D:collection/>"}}
  end

  def fetch(%Resource{}, {"DAV:", "resourcetype"}), do: {:ok, nil}

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
  def fetch(%Resource{collection?: true}, {"DAV:", "getcontentlength"}), do: :error
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
end
