defmodule Dav.CalDAVTester.Control do
  @moduledoc """
  The suite's back door into the deployment's directory.

  `sharing-groups-changes.xml` asks a question no CalDAV request can:
  *what happens to a share when the group it was granted to gains or
  loses a member?* Directory membership is not the protocol's to
  change, so the suite `POST`s JSON at `/control` and expects the
  server under test to do it — the reference server has exactly this
  endpoint, for exactly these tests.

  Four actions, and they are the whole vocabulary:

      {"action": "addgroupmembers", "group": "<uid>", "members": ["<uid>"]}
      {"action": "removegroupmembers", "group": "<uid>", "members": ["<uid>"]}
      {"action": "refreshgroups", "wait": true}
      {"action": "schedulingdone", "wait": true}

  The first two edit a group principal's `DAV:group-member-set`. The
  third is the one that matters: a directory change is not a request
  against any calendar, so something has to walk the calendars a group
  reaches and bring their shares up to date. That is
  `Dav.Cal.Sharing.regrouped/2`, called here for every calendar this
  deployment holds — which is a scan, and affordable only because this
  deployment is a test fixture. A real one would index shares by group.

  `schedulingdone` waits for scheduling to settle. In-process there is
  nothing to wait for, so it answers immediately.

  This is harness code, not library code: it exists because the
  deployment is the thing the suite is driving, and `Dav.Web.Plug`
  serves DAV rather than administration.

  """

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.Sharing
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @behaviour Plug

  @doc """
  Nothing to configure.

  ### Arguments

  * `options` are the plug's options, passed through.

  ### Returns

  * The options, unchanged.

  ### Examples

      iex> Dav.CalDAVTester.Control.init(store: nil)
      [store: nil]

  """
  @impl Plug
  def init(options), do: options

  @doc """
  Carry out one control action.

  ### Arguments

  * `conn` is the request, whose body is the JSON action.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The connection, answered `200` for an action it carried out and
    `400` for anything it does not recognise.

  """
  @impl Plug
  def call(conn, options) do
    {:ok, body, conn} = read_body(conn)

    case acted(body, Map.new(options)) do
      :ok -> send_resp(conn, 200, "")
      :error -> send_resp(conn, 400, "")
    end
  end

  defp acted(body, options) do
    case decoded(body) do
      %{"action" => "addgroupmembers"} = action -> membership(action, options, &Enum.concat/2)
      %{"action" => "removegroupmembers"} = action -> membership(action, options, &remove/2)
      %{"action" => "refreshgroups"} -> refreshed(options)
      %{"action" => "schedulingdone"} -> :ok
      _unrecognised -> :error
    end
  end

  # `:json.decode/1` raises on a malformed document and offers no
  # tuple-returning form.
  defp decoded(body) do
    :json.decode(body)
  rescue
    _malformed -> nil
  end

  defp remove(held, going), do: Enum.reject(held, &(&1 in going))

  # A group's membership is `DAV:group-member-set` on its principal,
  # which is where `Dav.Cal.Sharing` reads it from.
  defp membership(%{"group" => group, "members" => members}, options, change)
       when is_binary(group) and is_list(members) do
    with {:ok, principal} <- located(group, options),
         %{} = properties <- stored(principal, options) do
      held =
        case Map.get(properties, member_set()) do
          {:hrefs, hrefs} -> hrefs
          _unstated -> []
        end

      wanted = change.(held, Enum.map(members, &address/1)) |> Enum.uniq()

      options.store.patch(principal, [{:set, member_set(), {:hrefs, wanted}}], options.context)

      :ok
    else
      _no_such_group -> :error
    end
  end

  defp membership(_action, _options, _change), do: :error

  # The suite names people and groups by bare identifier here and by
  # `urn:x-uid:` everywhere else. One spelling reaches the directory.
  defp address("urn:x-uid:" <> _rest = urn), do: urn
  defp address(uid), do: "urn:x-uid:" <> uid

  defp located(uid, %{store: store, context: context}) do
    if Store.supports?(store, :principal),
      do: store.principal(address(uid), context),
      else: {:error, :not_found}
  end

  defp stored(resource, %{store: store, context: context}) do
    if Store.supports?(store, :properties), do: store.properties(resource, context), else: nil
  end

  defp member_set, do: {Xml.dav(), "group-member-set"}

  # Every calendar in the deployment, brought up to date. A share is
  # recorded on the calendar it is a share of, so there is nowhere
  # else to look without an index the store does not keep.
  defp refreshed(options) do
    for calendar <- calendars(options), do: Sharing.regrouped(calendar, options)

    :ok
  end

  defp calendars(%{store: store, context: context} = options) do
    case store.resolve([], context) do
      {:ok, %Resource{} = root} -> beneath(root, options)
      _nothing -> []
    end
  end

  defp beneath(collection, %{store: store, context: context} = options) do
    {:ok, children} = store.children(collection, context)

    Enum.flat_map(children, fn child ->
      cond do
        Cal.calendar?(child) -> [child]
        child.collection? -> beneath(child, options)
        true -> []
      end
    end)
  end
end
