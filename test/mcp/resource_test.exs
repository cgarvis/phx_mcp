defmodule MCP.ResourceTest do
  use ExUnit.Case, async: true

  alias MCP.TestSupport.{FailResource, ItemTemplate, NoteResource, SecretResource}

  test "use MCP.Resource generates the metadata callbacks" do
    assert NoteResource.uri() == "test://note"
    assert NoteResource.name() == "note"
    assert NoteResource.mime_type() == "text/plain"
    assert NoteResource.scopes() == []
    assert SecretResource.scopes() == ["secret:read"]
    assert FailResource.mime_type() == nil
  end

  test "build_resource_entries! materializes payloads, omitting a nil mimeType" do
    [note, fail] = MCP.Server.build_resource_entries!([NoteResource, FailResource])

    assert note.payload == %{
             "uri" => "test://note",
             "name" => "note",
             "description" => "A plain-text note",
             "mimeType" => "text/plain"
           }

    refute Map.has_key?(fail.payload, "mimeType")
  end

  test "build_resource_entries! rejects duplicate URIs" do
    assert_raise ArgumentError, ~r/duplicate MCP resource URIs/, fn ->
      MCP.Server.build_resource_entries!([NoteResource, NoteResource])
    end
  end

  test "build_template_entries! materializes payloads and rejects duplicates" do
    [entry] = MCP.Server.build_template_entries!([ItemTemplate])

    assert entry.payload == %{
             "uriTemplate" => "test://items/{id}",
             "name" => "item",
             "description" => "An item by id",
             "mimeType" => "application/json"
           }

    assert_raise ArgumentError, ~r/duplicate MCP resource template URIs/, fn ->
      MCP.Server.build_template_entries!([ItemTemplate, ItemTemplate])
    end
  end

  describe "generated struct" do
    test "a template defines a struct from its URI variables" do
      assert %ItemTemplate{id: "42"} == struct!(ItemTemplate, id: "42")
    end

    test "every variable is enforced, since a match always fills them all" do
      assert_raise ArgumentError, ~r/must also be given when building struct/, fn ->
        struct!(ItemTemplate, %{})
      end
    end

    test "a variable the template does not declare is a compile-time error" do
      source = """
      defmodule MCP.ResourceTest.Typo do
        use MCP.ResourceTemplate, uri_template: "test://typo/{id}", name: "typo"
        @impl true
        def description, do: "typo"
        @impl true
        def read(_uri, %__MODULE__{idd: id}, _ctx), do: {:ok, id}
      end
      """

      {_result, diagnostics} = Code.with_diagnostics(fn -> Code.eval_string(source) end)

      assert Enum.any?(diagnostics, fn d ->
               d.severity == :error and d.message =~ "unknown key :idd"
             end)
    end
  end
end
