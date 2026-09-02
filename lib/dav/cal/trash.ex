defmodule Dav.Cal.Trash do
  @moduledoc """
  Apple's trash collection — a deletion that can be taken back.

  A calendar object deleted from a calendar is not destroyed: its body
  is kept in a `trash` collection in the owner's calendar home, and
  the owner can put it back with a `POST` to the home:

      POST /calendars/__uids__/user01/?action=recovertrash&mode=event&id=all
      POST /calendars/__uids__/user01/?action=emptytrash

  Only the home's owner recovers or empties it — a delegate with write
  access included, anyone else refused.

  Trashing does not suspend scheduling. An organiser who trashes a
  meeting has cancelled it, an attendee who trashes an invitation has
  declined it, and both messages go out as they would for an outright
  delete: what the trash keeps is the copy, not the obligation.
  Recovery is the reverse — the restored copy is written back through
  the same path an ordinary save takes, so the organiser learns that
  an attendee who had declined is back with the answer they gave
  before.

  The trash is not a calendar. It is never scanned for free-busy, no
  report reaches into it, and it comes into existence the first time
  something is trashed rather than sitting in every home.

  """

  @behaviour Dav.Web.Hook

  import Plug.Conn

  alias Dav.Cal
  alias Dav.Cal.Delegation
  alias Dav.Web.Hook
  alias Dav.Web.Resource
  alias Dav.Web.Store

  @calendarserver "http://calendarserver.org/ns/"
  @calendar_type "text/calendar; charset=utf-8"
  @trash "trash"

  @doc """
  The trash applies to calendars, whose objects it keeps.

  ### Arguments

  * `collection` is the collection being written into or deleted from.

  ### Returns

  * `true` for a calendar, and for the calendar home the recovery
    actions are addressed to.

  """
  @impl Dav.Web.Hook
  @spec applies?(Resource.t() | nil) :: boolean()
  def applies?(%Resource{collection?: true} = collection), do: not held_in_trash?(collection.path)
  def applies?(_absent), do: false

  @doc """
  A write changes nothing the trash holds.

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
  The trash is the server's own area, not part of a client's view.

  ### Arguments

  * `resource` is the member being listed or reported.

  * `options` carries the request context, unused.

  ### Returns

  * `true` for the trash collection and anything inside it.

  """
  @impl Dav.Web.Hook
  @spec hidden?(Resource.t(), map()) :: boolean()
  def hidden?(%Resource{path: path}, _options), do: held_in_trash?(path)

  @doc """
  Keep a deleted calendar object where its owner can recover it.

  ### Arguments

  * `change` carries the deleted `:resource`, its `:body` as it stood,
    and the `:collection` it was deleted from.

  * `options` carries `:store` and `:context`.

  ### Returns

  * `:ok`, whether or not anything was kept — a delete is not refused
    because the trash could not take a copy.

  """
  @impl Dav.Web.Hook
  @spec deleted(map(), map()) :: :ok
  def deleted(%{resource: resource, body: body, collection: collection}, options) do
    origin = underlying(resource.path, options)

    result =
      with true <- keepable?(resource, collection, body),
           home when is_list(home) <- home_of(origin, options),
           {:ok, area} <- opened(home, options) do
        kept(area, origin, body, options)
      end

    if System.get_env("DBGTRASH"),
      do: IO.puts("DBGTRASH deleted #{inspect(resource.path)} -> #{inspect(result, limit: 3)}")

    :ok
  end

  def deleted(_change, _options), do: :ok

  # Only a calendar object is kept: an ordinary file, a scheduling
  # message consumed from an Inbox, or an attachment in the dropbox is
  # not something a calendar client asks to have back.
  defp keepable?(%Resource{collection?: true}, _collection, _body), do: false
  defp keepable?(_resource, _collection, ""), do: false

  defp keepable?(%Resource{path: path}, collection, body) do
    is_binary(body) and Cal.calendar?(collection) and not held_in_trash?(path)
  end

  defp held_in_trash?(path), do: @trash in path

  # The trash is made when it is first needed. A home that has never
  # had anything deleted from it does not grow a collection to say so.
  defp opened(home, %{store: store, context: context}) do
    area = home ++ [@trash]

    case store.resolve(area, context) do
      {:ok, %Resource{} = held} ->
        {:ok, held}

      _absent ->
        with true <- Store.supports?(store, :mkcol),
             {:ok, %Resource{} = made} <- store.mkcol(area, context) do
          {:ok, made}
        else
          _unmakeable -> :error
        end
    end
  end

  # The kept copy remembers where it came from, because that is the
  # one thing the body itself does not say.
  # A sharee deleting from a calendar shared with them deletes the
  # sharer's object through a view of it. What is kept — and who
  # recovers it — belongs to the calendar itself, so the view's
  # spelling is resolved to the real one first.
  defp underlying(path, %{store: store, context: context}) do
    if Store.supports?(store, :origin), do: store.origin(path, context), else: path
  end

  defp kept(area, origin, body, %{store: store, context: context} = options) do
    leaf = "#{:erlang.phash2({origin, System.unique_integer()})}.ics"
    path = area.path ++ [leaf]

    with true <- Store.supports?(store, :put),
         {:ok, _created_or_replaced, %Resource{} = kept} <-
           store.put(path, body, @calendar_type, context) do
      remember(kept, origin, options)
    end
  end

  defp remember(kept, origin, %{store: store, context: context}) do
    if Store.supports?(store, :patch) do
      store.patch(
        kept,
        [{:set, {@calendarserver, "trash-origin"}, Enum.join(origin, "/")}],
        context
      )
    end
  end

  defp origin_of(kept, %{store: store, context: context}) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(kept, context),
         stated when is_binary(stated) <- Map.get(properties, {@calendarserver, "trash-origin"}) do
      String.split(stated, "/", trim: true)
    else
      _unknown -> nil
    end
  end

  defp home_of(path, %{store: store, context: context}) do
    lineage = for n <- length(path)..1//-1, do: Enum.take(path, n)

    Enum.find(lineage, &home_at?(&1, store, context))
  end

  defp home_at?(ancestors, store, context) do
    case store.resolve(ancestors, context) do
      {:ok, %Resource{collection?: true, owner: owner} = held} when is_binary(owner) ->
        home?(held, store, context)

      _other ->
        false
    end
  end

  # A calendar home is the collection the calendars sit in.
  defp home?(collection, store, context) do
    case store.children(collection, context) do
      {:ok, children} -> Enum.any?(children, &Cal.calendar?/1)
      _nothing -> false
    end
  end

  @doc """
  Recover or empty the trash, addressed to the calendar home.

  `?action=recovertrash` puts every kept copy back where it was
  deleted from; `?action=emptytrash` destroys them. Both are the
  owner's to ask for.

  ### Arguments

  * `action` is the `action` query parameter.

  * `conn` is the request, with its body still unread.

  * `resource` is the resource posted to — the calendar home, for
    these two.

  * `options` carries `:store`, `:context`, `:principal` and `:hooks`.

  ### Returns

  * `{:ok, conn}` once answered, or `:unhandled` for any other action.

  """
  @impl Dav.Web.Hook
  @spec action(String.t(), Plug.Conn.t(), Resource.t(), map()) ::
          {:ok, Plug.Conn.t()} | :unhandled
  def action(action, conn, %Resource{collection?: true} = resource, options)
      when action in ~w(recovertrash emptytrash) do
    {:ok, _body, conn} = read_body(conn)

    if allowed?(resource, options) do
      {:ok, answered(action, conn, resource, options)}
    else
      {:ok, send_resp(conn, 403, "")}
    end
  end

  def action(_other, _conn, _resource, _options), do: :unhandled

  # The home is the owner's, and so is what was deleted from it. A
  # delegate with write access acts as the owner here as everywhere.
  defp allowed?(%Resource{owner: owner}, options) when is_binary(owner) do
    caller = Map.get(options, :principal)

    is_nil(caller) or Delegation.authorized_writer?(caller, owner, options)
  end

  defp allowed?(%Resource{}, _options), do: true

  defp answered("recovertrash", conn, home, options) do
    for kept <- kept_copies(home, options), do: recovered(kept, options)

    send_resp(conn, 200, "")
  end

  defp answered("emptytrash", conn, home, %{store: store, context: context} = options) do
    for kept <- kept_copies(home, options), do: store.delete(kept, context)

    send_resp(conn, 200, "")
  end

  defp kept_copies(home, %{store: store, context: context}) do
    with {:ok, %Resource{} = area} <- store.resolve(home.path ++ [@trash], context),
         {:ok, children} <- store.children(area, context) do
      Enum.reject(children, & &1.collection?)
    else
      _nothing_trashed -> []
    end
  end

  # Put back through the write path an ordinary save takes, so the
  # scheduling that a trashing triggered is answered by the scheduling
  # a restoration triggers: the attendee who declined by deleting says
  # again what they had said before.
  defp recovered(kept, %{store: store, context: context} = options) do
    if System.get_env("DBGTRASH"),
      do:
        IO.puts(
          "DBGTRASH recover #{inspect(kept.path)} origin=#{inspect(origin_of(kept, options))}"
        )

    with origin when is_list(origin) <- origin_of(kept, options),
         {:ok, body} <- store.read(kept, context),
         {:ok, collection} <- store.resolve(Enum.drop(origin, -1), context),
         {:ok, _created_or_replaced, %Resource{} = restored} <-
           store.put(origin, IO.iodata_to_binary(body), @calendar_type, context) do
      Hook.saving(
        %{
          resource: restored,
          body: IO.iodata_to_binary(body),
          previous: nil,
          collection: collection
        },
        options
      )

      store.delete(kept, context)
    else
      # A copy whose calendar is gone has nowhere to go back to. It
      # stays in the trash rather than being lost twice.
      _unrecoverable -> :ok
    end
  end
end
