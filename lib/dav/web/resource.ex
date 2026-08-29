defmodule Dav.Web.Resource do
  @moduledoc """
  One addressable thing in a DAV namespace.

  A resource is either a **collection** — a container of other
  resources, which is what a directory and a calendar both are — or an
  ordinary resource with a body. The distinction matters more than it
  looks: `Depth` applies to collections, `PROPFIND` reports them with a
  `DAV:collection` resource type, and a `PUT` to one is an error.

  Everything here is *live* property material — values a server
  computes rather than values a client stored. Dead properties, which
  clients set with `PROPPATCH` and expect back verbatim, belong to the
  store and not to this struct.

  """

  @typedoc "An addressable resource in a DAV namespace."
  @type t :: %__MODULE__{
          path: [String.t()],
          collection?: boolean(),
          etag: String.t() | nil,
          content_type: String.t() | nil,
          content_length: non_neg_integer() | nil,
          modified_at: DateTime.t() | nil,
          display_name: String.t() | nil
        }

  defstruct path: [],
            collection?: false,
            etag: nil,
            content_type: nil,
            content_length: nil,
            modified_at: nil,
            display_name: nil

  @doc """
  The resource's URL path, with the trailing slash a collection needs.

  Clients are entitled to treat a collection URL without its trailing
  slash as a different resource, and some will follow the redirect
  rather than the data. Emitting it consistently is cheaper than
  explaining why a client resynchronises everything.

  ### Arguments

  * `resource` is a `t:t/0`.

  ### Returns

  * The path as a string, beginning with `/`, and ending with `/` when
    the resource is a collection.

  ### Examples

      iex> Dav.Web.Resource.href(%Dav.Web.Resource{path: ["calendars", "kim"], collection?: true})
      "/calendars/kim/"

      iex> Dav.Web.Resource.href(%Dav.Web.Resource{path: ["calendars", "kim", "1.ics"]})
      "/calendars/kim/1.ics"

      iex> Dav.Web.Resource.href(%Dav.Web.Resource{path: [], collection?: true})
      "/"

  """
  @spec href(t()) :: String.t()
  def href(%__MODULE__{path: path, collection?: collection?}) do
    joined = Enum.map_join(path, "/", &URI.encode/1)

    case {joined, collection?} do
      {"", _any} -> "/"
      {segments, true} -> "/" <> segments <> "/"
      {segments, false} -> "/" <> segments
    end
  end

  @doc """
  The resource's name within its parent collection.

  ### Arguments

  * `resource` is a `t:t/0`.

  ### Returns

  * The last path segment, or `nil` at the root.

  ### Examples

      iex> Dav.Web.Resource.name(%Dav.Web.Resource{path: ["calendars", "kim"]})
      "kim"

      iex> Dav.Web.Resource.name(%Dav.Web.Resource{path: []})
      nil

  """
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{path: []}), do: nil
  def name(%__MODULE__{path: path}), do: List.last(path)
end
