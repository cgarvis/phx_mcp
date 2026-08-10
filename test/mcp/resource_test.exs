defmodule MCP.ResourceTest do
  use ExUnit.Case, async: true

  alias MCP.TestSupport.{FailResource, ItemTemplate, NoteResource, SecretResource}

  defmodule CachedResource do
    @moduledoc false

    use MCP.Resource,
      uri: "test://cached",
      name: "cached",
      mime_type: "text/plain",
      title: "Cached Note",
      annotations: [audience: [:user]],
      cache_scope: "public",
      ttl_ms: 5_000

    @impl true
    def description, do: "A cacheable note"

    @impl true
    def read(_ctx), do: {:ok, "cached"}
  end

  defmodule CompletableTemplate do
    @moduledoc false

    use MCP.ResourceTemplate, uri_template: "test://completable/{id}", name: "completable"

    @impl true
    def description, do: "A template with completions"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}

    @impl true
    def complete("id", value, _ctx) do
      {:ok, Enum.filter(["alpha", "beta", "gamma"], &String.starts_with?(&1, value))}
    end
  end

  test "use MCP.Resource generates the metadata callbacks" do
    assert NoteResource.uri() == "test://note"
    assert NoteResource.name() == "note"
    assert NoteResource.mime_type() == "text/plain"
    assert NoteResource.scopes() == []
    assert SecretResource.scopes() == ["secret:read"]
    assert FailResource.mime_type() == nil
  end

  test "title, annotations, cache_scope, and ttl_ms default to nil when undeclared" do
    assert NoteResource.title() == nil
    assert NoteResource.annotations() == nil
    assert NoteResource.cache_scope() == nil
    assert NoteResource.ttl_ms() == nil
    assert ItemTemplate.title() == nil
    assert ItemTemplate.annotations() == nil
    assert ItemTemplate.cache_scope() == nil
    assert ItemTemplate.ttl_ms() == nil
  end

  test "title, annotations, cache_scope, and ttl_ms return the declared values" do
    assert CachedResource.title() == "Cached Note"
    assert CachedResource.annotations() == %{"audience" => ["user"]}
    assert CachedResource.cache_scope() == "public"
    assert CachedResource.ttl_ms() == 5_000
  end

  test "cache_scope must be \"public\" or \"private\"" do
    source = """
    defmodule MCP.ResourceTest.BadCacheScope do
      use MCP.Resource,
        uri: "test://bad-cache-scope",
        name: "bad-cache-scope",
        cache_scope: "bogus"

      @impl true
      def description, do: "bad"
      @impl true
      def read(_ctx), do: {:ok, "x"}
    end
    """

    assert_raise ArgumentError, ~r/invalid MCP cache_scope/, fn ->
      Code.eval_string(source)
    end
  end

  test "a resource template's cache_scope is validated too" do
    source = """
    defmodule MCP.ResourceTest.BadTemplateCacheScope do
      use MCP.ResourceTemplate,
        uri_template: "test://bad-cache-scope/{id}",
        name: "bad-cache-scope",
        cache_scope: "bogus"
      @impl true
      def description, do: "bad"
      @impl true
      def read(_uri, _params, _ctx), do: {:ok, "x"}
    end
    """

    assert_raise ArgumentError, ~r/invalid MCP cache_scope/, fn ->
      Code.eval_string(source)
    end
  end

  test "ttl_ms must be a positive integer" do
    zero_source = """
    defmodule MCP.ResourceTest.ZeroTtl do
      use MCP.Resource, uri: "test://zero-ttl", name: "zero-ttl", ttl_ms: 0
      @impl true
      def description, do: "bad"
      @impl true
      def read(_ctx), do: {:ok, "x"}
    end
    """

    string_source = """
    defmodule MCP.ResourceTest.StringTtl do
      use MCP.Resource, uri: "test://string-ttl", name: "string-ttl", ttl_ms: "x"
      @impl true
      def description, do: "bad"
      @impl true
      def read(_ctx), do: {:ok, "x"}
    end
    """

    assert_raise ArgumentError, ~r/ttl_ms/, fn -> Code.eval_string(zero_source) end
    assert_raise ArgumentError, ~r/ttl_ms/, fn -> Code.eval_string(string_source) end
  end

  test "complete/3 is optional: exported when declared, absent otherwise" do
    assert function_exported?(CompletableTemplate, :complete, 3)
    refute function_exported?(ItemTemplate, :complete, 3)
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
