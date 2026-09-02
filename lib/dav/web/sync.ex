defmodule Dav.Web.Sync do
  @moduledoc """
  The `DAV:sync-collection` report — RFC 6578.

  The report that spares a polling client the whole collection. It
  holds the `DAV:sync-token` from its last visit and asks what happened
  since: members created or modified come back as responses with the
  properties it asked for, members deleted come back as bare `404`
  responses, and the root of the multistatus carries the token to hold
  next time. An initial synchronisation — an empty token — answers with
  everything, the collection itself included.

  The store keeps the history; this module keeps the grammar. A
  collection is synchronisable when the store reports a token for it —
  see `c:Dav.Web.Store.sync_token/2` and `c:Dav.Web.Store.changes/4` —
  and the `DAV:sync-collection` entry appears in that collection's
  `DAV:supported-report-set` on the same condition.

  Three refusals the specification names: a token the store never
  issued is `DAV:valid-sync-token`; a `DAV:limit` this server does not
  honour is `DAV:number-of-matches-within-limits`; and a
  `DAV:sync-level` that is neither `1` nor `infinity` is a malformed
  request.

  """

  @behaviour Dav.Web.Report

  alias Dav.Web.Hook
  alias Dav.Web.Hook
  alias Dav.Web.Properties
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  @impl Dav.Web.Report
  def run(%Resource{} = target, body, depth, options) do
    with {:ok, document} <- Xml.parse(body),
         :ok <- unlimited(document),
         :ok <- levelled(document),
         :ok <- synchronised(target, options),
         {:ok, fresh, changed, removed} <-
           happened(target, token_of(document), scope_of(document, depth), options) do
      wanted = requested(document)

      # An extension's own working area is not a client's business: a
      # calendar's trash is reported neither as a member nor as a
      # change, the same way it is left out of a listing.
      shown = Enum.reject(changed, &Hook.concealed?(&1, options))

      responses =
        arrival(target, token_of(document), wanted, fresh, options) ++
          Enum.map(shown, &answered(versioned(&1, fresh), wanted, options)) ++
          Enum.map(removed, &gone/1)

      {:ok, {:multistatus, responses, [{{Xml.dav(), "sync-token"}, fresh}]}}
    end
  end

  # A limit is honoured or refused, never ignored: a client trusting a
  # truncated answer to be complete would delete everything the
  # truncation left out.
  defp unlimited(document) do
    if Enum.any?(document.children, &named?(&1, "limit")),
      do: {:error, {Xml.dav(), "number-of-matches-within-limits"}},
      else: :ok
  end

  defp levelled(document) do
    case Enum.find(document.children, &named?(&1, "sync-level")) do
      nil ->
        :ok

      element ->
        if String.trim(element.text) in ["1", "infinity", "infinite"],
          do: :ok,
          else: {:error, :malformed}
    end
  end

  # The report runs where the store keeps a history. Anywhere else it
  # is not among the supported reports — the same answer the client
  # would have read in `DAV:supported-report-set`.
  defp synchronised(%Resource{} = target, %{store: store, context: context}) do
    if Store.supports?(store, :sync_token) and store.sync_token(target, context) != nil,
      do: :ok,
      else: {:error, {Xml.dav(), "supported-report"}}
  end

  defp token_of(document) do
    case Enum.find(document.children, &named?(&1, "sync-token")) do
      nil -> nil
      element -> presented(String.trim(element.text))
    end
  end

  defp presented(""), do: nil
  defp presented(token), do: token

  # `DAV:sync-level` `1` asks about the collection's own members;
  # `infinity` about everything beneath it. Absent means `1` — the
  # level RFC 6578 requires every server to support.
  # A request without the element predates RFC 6578's final grammar,
  # and the reference server reads the `Depth` header in its place.
  defp scope_of(document, depth) do
    case Enum.find(document.children, &named?(&1, "sync-level")) do
      nil ->
        if depth == :infinity, do: :tree, else: :members

      element ->
        if String.trim(element.text) in ["infinity", "infinite"], do: :tree, else: :members
    end
  end

  defp happened(target, token, scope, %{store: store, context: context}) do
    case store.changes(target, token, scope, context) do
      {:ok, fresh, changed, removed} -> {:ok, fresh, changed, removed}
      {:error, :invalid_sync_token} -> {:error, {Xml.dav(), "valid-sync-token"}}
    end
  end

  defp requested(document) do
    case Enum.find(document.children, &named?(&1, "prop")) do
      nil -> []
      element -> for child <- element.children, do: child.name
    end
  end

  # An initial synchronisation reports the collection itself along
  # with its members — the client learns the collection's own state
  # once, and every later difference is expressed against it. The
  # collection answers for `DAV:getetag` with the version its token
  # names, the way the reference server's collections carry one, and a
  # client caching by etag invalidates exactly when the token moves.
  defp arrival(%Resource{} = target, nil, wanted, fresh, options) do
    [answered(versioned(target, fresh), wanted, options)]
  end

  defp arrival(%Resource{}, _token, _wanted, _fresh, _options), do: []

  defp versioned(%Resource{collection?: true} = target, fresh) do
    %{
      target
      | etag: target.etag || ~s("#{fresh}"),
        content_type: target.content_type || "httpd/unix-directory"
    }
  end

  defp versioned(%Resource{} = member, _fresh), do: member

  # With no properties asked for, a member's answer is its presence: a
  # bare `200` beside the href, the shape a `MOVE` multistatus uses.
  defp answered(%Resource{} = member, [], _options) do
    {Resource.href(member), {:status, "HTTP/1.1 200 OK"}}
  end

  defp answered(%Resource{} = member, wanted, options) do
    stored = stored_of(member, options)

    {found, missing} =
      Enum.reduce(wanted, {[], []}, fn name, {found, missing} ->
        case value_of(member, name, stored, options) do
          {:ok, value} -> {found ++ [{name, value}], missing}
          :error -> {found, missing ++ [{name, nil}]}
        end
      end)

    propstats =
      [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)
      |> minimal(options)

    {Resource.href(member), propstats}
  end

  # `Prefer: return=minimal` spares the client the `404` propstats —
  # it asked to be told what is there, not what is not.
  defp minimal(propstats, %{minimal: true}) do
    Enum.reject(propstats, fn {status, _properties} -> String.contains?(status, "404") end)
  end

  defp minimal(propstats, _options), do: propstats

  # What a client stored with `PROPPATCH`, and what an extension
  # computes — a calendar's colour, its
  # `CALDAV:schedule-calendar-transp` — answers here the way it would
  # in a `PROPFIND`, not as a property the resource is missing.
  defp stored_of(%Resource{} = member, %{store: store, context: context} = options) do
    stored =
      if Store.supports?(store, :properties), do: store.properties(member, context), else: %{}

    Map.merge(stored, contributed_of(member, options))
  end

  defp contributed_of(%Resource{} = member, %{store: store, context: context} = options) do
    collection =
      case store.resolve(Enum.drop(member.path, -1), context) do
        {:ok, parent} -> parent
        _no_parent -> nil
      end

    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :properties, 3)))
    |> Enum.flat_map(& &1.properties(member, collection, options))
    |> Map.new()
  end

  defp value_of(member, name, stored, options) do
    cond do
      calendar_data?(name) ->
        {:ok, held(member, [name], options)}

      match?({:ok, _value}, Properties.fetch(member, name)) ->
        Properties.fetch(member, name)

      true ->
        Map.fetch(stored, name)
    end
  end

  # The body is read only when `CALDAV:calendar-data` was asked for —
  # synchronisation normally wants the etags, and fetches the few
  # bodies that changed with a multiget.
  defp held(%Resource{collection?: true}, _wanted, _options), do: ""

  defp held(%Resource{} = member, wanted, %{store: store, context: context} = options) do
    if Enum.any?(wanted, &calendar_data?/1) and Store.supports?(store, :read) do
      with {:ok, data} <- store.read(member, context),
           {:ok, body} <- Hook.disclosure(member, IO.iodata_to_binary(data), options) do
        body
      else
        _unreadable -> ""
      end
    else
      ""
    end
  end

  defp calendar_data?({namespace, "calendar-data"}), do: namespace == Xml.caldav()
  defp calendar_data?(_name), do: false

  defp gone(path) do
    {Resource.href(%Resource{path: path}), {:status, "HTTP/1.1 404 Not Found"}}
  end

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
