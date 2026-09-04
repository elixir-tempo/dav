defmodule Dav.CalDAVTester.Indexes do
  @moduledoc """
  The collections this deployment will not enumerate.

  `/principals/__uids__/` and `/calendars/__uids__/` are indexes: every
  principal and every calendar home is addressable through one of them
  by its stable identifier, which is why the suite's fixtures reach
  for `$principals_uids:` constantly. What is addressable there is not
  therefore listable — a listing of an index keyed by identifier is a
  list of every identifier the deployment has, handed to anyone who
  can authenticate.

  The reference server refuses the same two, and `directory.xml`
  checks it. This is deployment policy rather than a rule of the
  protocol, which is why it lives in the harness and reaches
  `Dav.Web.Plug` through `c:Dav.Web.Hook.rendered/2` — the seam that
  decides what a `GET` on a collection returns.

  """

  @behaviour Dav.Web.Hook

  alias Dav.Web.Resource

  @doc """
  This hook watches collections rather than writes, so it applies to
  none of them.

  ### Arguments

  * `collection` is the collection being written into, unused.

  ### Returns

  * `false`.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(_collection), do: false

  @doc """
  A write changes nothing here.

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
  Refuse to render an identifier index.

  ### Arguments

  * `collection` is the collection a `GET` addressed.

  * `options` carries the request context, unused.

  ### Returns

  * `{:error, :forbidden}` for an index, and `:skip` for everything
    else — including the resources *inside* an index, which are
    ordinary homes and principals and are read as such.

  """
  @impl Dav.Web.Hook
  @spec rendered(Resource.t(), map()) :: {:error, :forbidden} | :skip
  def rendered(%Resource{path: path}, _options) do
    if List.last(path) == "__uids__", do: {:error, :forbidden}, else: :skip
  end
end
