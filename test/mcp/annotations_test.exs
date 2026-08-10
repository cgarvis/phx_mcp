defmodule MCP.AnnotationsTest do
  use ExUnit.Case, async: true

  alias MCP.Annotations

  describe "resource!/1" do
    test "nil and an empty list are both absent, not an empty object" do
      assert Annotations.resource!(nil) == nil
      assert Annotations.resource!([]) == nil
    end

    test "maps every key to its spec wire name" do
      assert Annotations.resource!(
               audience: [:assistant, :user],
               priority: 0.8,
               last_modified: "2026-08-06T12:00:00Z"
             ) == %{
               "audience" => ["assistant", "user"],
               "priority" => 0.8,
               "lastModified" => "2026-08-06T12:00:00Z"
             }
    end

    test "accepts a partial declaration" do
      assert Annotations.resource!(audience: [:assistant]) == %{"audience" => ["assistant"]}
    end

    test "priority accepts the inclusive bounds and an integer" do
      assert Annotations.resource!(priority: 0) == %{"priority" => 0}
      assert Annotations.resource!(priority: 1) == %{"priority" => 1}
    end

    test "rejects an unknown key" do
      assert_raise ArgumentError, ~r/unknown MCP resource annotation :audiance/, fn ->
        Annotations.resource!(audiance: [:user])
      end
    end

    # The whole point of typing these: a tool hint on a resource is meaningless.
    test "rejects a tool annotation key" do
      assert_raise ArgumentError, ~r/unknown MCP resource annotation :read_only/, fn ->
        Annotations.resource!(read_only: true)
      end
    end

    test "rejects an unknown audience role" do
      assert_raise ArgumentError, ~r/invalid MCP audience :admin/, fn ->
        Annotations.resource!(audience: [:admin])
      end
    end

    test "rejects an empty or non-list audience" do
      assert_raise ArgumentError, ~r/invalid MCP audience/, fn ->
        Annotations.resource!(audience: [])
      end

      assert_raise ArgumentError, ~r/invalid MCP audience/, fn ->
        Annotations.resource!(audience: :assistant)
      end
    end

    test "rejects duplicate audience roles" do
      assert_raise ArgumentError, ~r/duplicate MCP audience roles/, fn ->
        Annotations.resource!(audience: [:user, :user])
      end
    end

    test "rejects a priority outside 0..1" do
      assert_raise ArgumentError, ~r/invalid MCP priority 5/, fn ->
        Annotations.resource!(priority: 5)
      end

      assert_raise ArgumentError, ~r/invalid MCP priority -1/, fn ->
        Annotations.resource!(priority: -1)
      end

      assert_raise ArgumentError, ~r/invalid MCP priority "high"/, fn ->
        Annotations.resource!(priority: "high")
      end
    end

    test "rejects a last_modified that is not an ISO 8601 timestamp" do
      assert_raise ArgumentError, ~r/not an ISO 8601 timestamp/, fn ->
        Annotations.resource!(last_modified: "last tuesday")
      end

      assert_raise ArgumentError, ~r/expected an ISO 8601 string/, fn ->
        Annotations.resource!(last_modified: 1_754_486_400)
      end
    end

    test "rejects a bare map, which is what this replaced" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        Annotations.resource!(%{"audience" => ["user"]})
      end
    end

    test "rejects duplicate keys" do
      assert_raise ArgumentError, ~r/duplicate MCP resource annotations/, fn ->
        Annotations.resource!(priority: 0.1, priority: 0.2)
      end
    end
  end

  describe "tool!/1" do
    test "nil and an empty list are both absent" do
      assert Annotations.tool!(nil) == nil
      assert Annotations.tool!([]) == nil
    end

    test "maps every hint to its spec wire name" do
      assert Annotations.tool!(
               read_only: true,
               destructive: false,
               idempotent: true,
               open_world: false
             ) == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end

    test "rejects an unknown key" do
      assert_raise ArgumentError, ~r/unknown MCP tool annotation :readOnlyHint/, fn ->
        Annotations.tool!(readOnlyHint: true)
      end
    end

    test "rejects a resource annotation key" do
      assert_raise ArgumentError, ~r/unknown MCP tool annotation :audience/, fn ->
        Annotations.tool!(audience: [:user])
      end
    end

    # title lives at the top level of the tool payload; two sources would drift.
    test "rejects title, which is its own use option" do
      assert_raise ArgumentError, ~r/unknown MCP tool annotation :title/, fn ->
        Annotations.tool!(title: "Get my labs")
      end
    end

    test "rejects a non-boolean hint" do
      assert_raise ArgumentError, ~r/invalid MCP tool annotation :read_only/, fn ->
        Annotations.tool!(read_only: "yes")
      end
    end

    test "rejects a bare map" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        Annotations.tool!(%{"readOnlyHint" => true})
      end
    end
  end

  describe "at the declaration site" do
    test "a bad annotation fails the using module's compile, not a request" do
      assert_raise ArgumentError, ~r/unknown MCP tool annotation :destructiveHint/, fn ->
        Code.eval_string("""
        defmodule MCP.AnnotationsTest.BadTool do
          use MCP.Tool, name: "bad", annotations: [destructiveHint: true]
          @impl true
          def description, do: "nope"
          input do
          end
          @impl true
          def call(_args, _ctx), do: {:ok, %{}}
        end
        """)
      end
    end

    test "a bad resource annotation fails the same way" do
      assert_raise ArgumentError, ~r/invalid MCP priority/, fn ->
        Code.eval_string("""
        defmodule MCP.AnnotationsTest.BadResource do
          use MCP.Resource, uri: "t://bad", name: "bad", annotations: [priority: 99]
          @impl true
          def description, do: "nope"
          @impl true
          def read(_ctx), do: {:ok, %{}}
        end
        """)
      end
    end
  end
end
