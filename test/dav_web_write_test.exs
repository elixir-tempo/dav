defmodule Dav.Web.WriteTest do
  use ExUnit.Case, async: true

  alias Dav.Test.MemoryStore
  alias Dav.Test.WritableStore
  alias Dav.Web.Resource
  alias Dav.Web.Write

  doctest Dav.Web.Write

  defmodule Refusing do
    @moduledoc false
    @behaviour Dav.Web.Validator

    @impl Dav.Web.Validator
    def applies?(_collection), do: true

    @impl Dav.Web.Validator
    def permit_collection(_collection), do: :ok

    @impl Dav.Web.Validator
    def validate(body, _collection, _path, _options) do
      if body =~ "forbidden", do: {:error, {"DAV:", "no"}}, else: :ok
    end
  end

  defmodule Recording do
    @moduledoc false
    @behaviour Dav.Web.Hook

    @impl Dav.Web.Hook
    def applies?(_collection), do: true

    @impl Dav.Web.Hook
    def written(change, %{recorder: recorder}) do
      send(recorder, {:written, change.body, change.previous, change.merge})
      :ok
    end
  end

  setup do
    agent =
      WritableStore.start([
        %Resource{path: [], collection?: true},
        %Resource{path: ["files"], collection?: true}
      ])

    %{
      options: %{
        store: WritableStore,
        context: agent,
        validators: [Refusing],
        hooks: [Recording],
        recorder: self()
      }
    }
  end

  describe "document/5" do
    test "stores a document and reports what it became", context do
      assert {:ok, :created, %Resource{} = resource} =
               Write.document(["files", "a.txt"], "one", "text/plain", context.options)

      assert resource.path == ["files", "a.txt"]
      assert Write.contents(resource, context.options) == "one"
    end

    test "a second write replaces rather than creates", context do
      Write.document(["files", "a.txt"], "one", "text/plain", context.options)

      assert {:ok, :replaced, _resource} =
               Write.document(["files", "a.txt"], "two", "text/plain", context.options)
    end

    # The validators are what stand between a store and data that has
    # no business being in it, so a caller reaching this function must
    # not be able to walk past them.
    test "a validator's refusal stops the write", context do
      assert {:error, {"DAV:", "no"}} =
               Write.document(["files", "a.txt"], "forbidden", "text/plain", context.options)

      assert WritableStore.resolve(["files", "a.txt"], context.options.context) ==
               {:error, :not_found}
    end

    # RFC 6638's invitations go out from here. A write that skipped
    # the hooks would store the meeting and tell nobody.
    test "the hooks hear what was written and what it replaced", context do
      Write.document(["files", "a.txt"], "one", "text/plain", context.options)
      assert_received {:written, "one", nil, false}

      Write.document(["files", "a.txt"], "two", "text/plain", context.options)
      assert_received {:written, "two", "one", false}
    end

    test "the merge option reaches the hooks", context do
      Write.document(["files", "a.txt"], "one", "text/plain", context.options, merge: true)

      assert_received {:written, "one", nil, true}
    end

    # RFC 4918 section 9.7.2 leaves `PUT` over a collection undefined,
    # and a server that obeyed it would have to decide what became of
    # everything inside.
    test "a collection is not a document", context do
      assert {:error, :collection} =
               Write.document(["files"], "one", "text/plain", context.options)
    end

    test "a store that does not write says so rather than failing", _context do
      assert {:error, :unsupported} =
               Write.document(["files", "a.txt"], "one", "text/plain", %{
                 store: MemoryStore,
                 context: []
               })
    end
  end
end
