defmodule MCP.ResourceLinkTest do
  use ExUnit.Case, async: true

  alias MCP.ResourceLink

  describe "new!/1" do
    test "the two required keys are enough for a block" do
      assert ResourceLink.new!(%{uri: "test://items/42", name: "item-42"}) == %{
               "type" => "resource_link",
               "uri" => "test://items/42",
               "name" => "item-42"
             }
    end

    test "maps every optional key to its spec wire name" do
      link = %{
        uri: "test://items/42",
        name: "item-42",
        title: "Item 42",
        description: "One item",
        mime_type: "application/json",
        annotations: [audience: [:assistant], priority: 0.4]
      }

      assert ResourceLink.new!(link) == %{
               "type" => "resource_link",
               "uri" => "test://items/42",
               "name" => "item-42",
               "title" => "Item 42",
               "description" => "One item",
               "mimeType" => "application/json",
               "annotations" => %{"audience" => ["assistant"], "priority" => 0.4}
             }
    end

    # snake_case in, camelCase out, the same split MCP.Annotations keeps.
    test "mime_type is the only name that changes shape" do
      link = ResourceLink.new!(%{uri: "test://n", name: "n", mime_type: "text/plain"})

      assert link["mimeType"] == "text/plain"
      refute Map.has_key?(link, "mime_type")
    end

    test "a keyword list is accepted wherever a map is" do
      assert ResourceLink.new!(uri: "test://items/42", name: "item-42") ==
               ResourceLink.new!(%{uri: "test://items/42", name: "item-42"})
    end

    # So a tool can compute an optional value without branching around it.
    test "an optional key present with nil is absent, not null" do
      link = ResourceLink.new!(%{uri: "test://n", name: "n", title: nil, annotations: nil})

      refute Map.has_key?(link, "title")
      refute Map.has_key?(link, "annotations")
    end

    test "rejects a missing uri" do
      assert_raise ArgumentError, ~r/missing required :uri/, fn ->
        ResourceLink.new!(%{name: "item-42"})
      end
    end

    test "rejects a missing name" do
      assert_raise ArgumentError, ~r/missing required :name/, fn ->
        ResourceLink.new!(%{uri: "test://items/42"})
      end
    end

    # A link to "" is a link to nothing; the client has nothing to read with.
    test "rejects a non-string or empty uri" do
      assert_raise ArgumentError, ~r/invalid MCP resource link :uri 42/, fn ->
        ResourceLink.new!(%{uri: 42, name: "item-42"})
      end

      assert_raise ArgumentError, ~r/expected a non-empty string/, fn ->
        ResourceLink.new!(%{uri: "", name: "item-42"})
      end
    end

    test "rejects an unknown key" do
      assert_raise ArgumentError, ~r/unknown MCP resource link key :mimetype/, fn ->
        ResourceLink.new!(%{uri: "test://n", name: "n", mimetype: "text/plain"})
      end
    end

    # String keys are the wire shape, not the input shape.
    test "rejects string keys" do
      assert_raise ArgumentError, ~r/unknown MCP resource link key "(uri|name)"/, fn ->
        ResourceLink.new!(%{"uri" => "test://n", "name" => "n"})
      end
    end

    test "rejects a non-string optional value" do
      assert_raise ArgumentError, ~r/invalid MCP resource link :title/, fn ->
        ResourceLink.new!(%{uri: "test://n", name: "n", title: :item})
      end
    end

    test "annotations go through the same validation resources use" do
      assert_raise ArgumentError, ~r/invalid MCP priority/, fn ->
        ResourceLink.new!(%{uri: "test://n", name: "n", annotations: [priority: 99]})
      end

      assert_raise ArgumentError, ~r/unknown MCP resource annotation :read_only/, fn ->
        ResourceLink.new!(%{uri: "test://n", name: "n", annotations: [read_only: true]})
      end
    end

    test "rejects anything that is not a map or keyword list" do
      assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
        ResourceLink.new!("test://items/42")
      end

      assert_raise ArgumentError, ~r/expected a map or keyword list/, fn ->
        ResourceLink.new!(["test://items/42"])
      end
    end
  end
end
