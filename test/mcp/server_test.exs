defmodule MCP.ServerTest do
  use ExUnit.Case, async: true

  defmodule TitledTool do
    @moduledoc false

    use MCP.Tool,
      name: "titled-tool",
      scopes: [],
      title: "Titled Tool",
      annotations: [read_only: true]

    @impl true
    def description, do: "A tool with a title and annotations"

    @impl true
    def call(_args, _ctx), do: {:ok, %{}}
  end

  defmodule BareTool do
    @moduledoc false

    use MCP.Tool, name: "bare-tool", scopes: []

    @impl true
    def description, do: "A tool without a title or annotations"

    @impl true
    def call(_args, _ctx), do: {:ok, %{}}
  end

  defmodule TitledResource do
    @moduledoc false

    use MCP.Resource,
      uri: "servertest://titled",
      name: "titled-resource",
      mime_type: "text/plain",
      scopes: [],
      title: "Titled Resource",
      annotations: [audience: [:user]]

    @impl true
    def description, do: "A resource with a title and annotations"

    @impl true
    def read(_ctx), do: {:ok, "titled"}
  end

  defmodule BareResource do
    @moduledoc false

    use MCP.Resource, uri: "servertest://bare", name: "bare-resource", scopes: []

    @impl true
    def description, do: "A resource without a title, annotations, or cache override"

    @impl true
    def read(_ctx), do: {:ok, "bare"}
  end

  defmodule OverriddenTtlResource do
    @moduledoc false

    use MCP.Resource,
      uri: "servertest://overridden-ttl",
      name: "overridden-ttl",
      scopes: [],
      ttl_ms: 5_000

    @impl true
    def description, do: "Overrides only ttl_ms"

    @impl true
    def read(_ctx), do: {:ok, "ttl"}
  end

  defmodule OverriddenScopeResource do
    @moduledoc false

    use MCP.Resource,
      uri: "servertest://overridden-scope",
      name: "overridden-scope",
      scopes: [],
      cache_scope: "public"

    @impl true
    def description, do: "Overrides only cache_scope"

    @impl true
    def read(_ctx), do: {:ok, "scope"}
  end

  defmodule TitledTemplate do
    @moduledoc false

    use MCP.ResourceTemplate,
      uri_template: "servertest://titled/{id}",
      name: "titled-template",
      scopes: [],
      title: "Titled Template",
      annotations: [audience: [:assistant]],
      cache_scope: "public",
      ttl_ms: 9_000

    @impl true
    def description, do: "A template with a title, annotations, and full cache override"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}
  end

  defmodule BareTemplate do
    @moduledoc false

    use MCP.ResourceTemplate, uri_template: "servertest://bare/{id}", name: "bare-template"

    @impl true
    def description, do: "A template without a title, annotations, or cache override"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}
  end

  defmodule TitledPrompt do
    @moduledoc false

    use MCP.Prompt, name: "titled-prompt", scopes: [], title: "Titled Prompt"

    @impl true
    def description, do: "A prompt with a title"

    @impl true
    def get(_args, _ctx), do: {:ok, [{:user, "hi"}]}
  end

  defmodule BarePrompt do
    @moduledoc false

    use MCP.Prompt, name: "bare-prompt", scopes: []

    @impl true
    def description, do: "A prompt without a title"

    @impl true
    def get(_args, _ctx), do: {:ok, [{:user, "hi"}]}
  end

  defmodule AnnotatedPrompt do
    @moduledoc false

    use MCP.Prompt, name: "annotated-prompt", scopes: []

    @impl true
    def description, do: "A prompt whose messages carry content annotations"

    @impl true
    def get(_args, _ctx) do
      {:ok,
       [
         {:user, "for the model", audience: [:assistant], priority: 0.9},
         {:assistant, "plain"}
       ]}
    end
  end

  defmodule BadAnnotationPrompt do
    @moduledoc false

    use MCP.Prompt, name: "bad-annotation-prompt", scopes: []

    @impl true
    def description, do: "Annotations that should not validate"

    @impl true
    def get(_args, _ctx), do: {:ok, [{:user, "x", audience: [:nobody]}]}
  end

  defmodule PromptServer do
    @moduledoc "Kernel test fixture: prompt message content annotations."

    use MCP.Server,
      name: "prompt-server",
      version: "1.0.0",
      prompts: [AnnotatedPrompt, BadAnnotationPrompt]
  end

  defp get_prompt_request(name),
    do: %MCP.RPC.Request{id: 1, method: "prompts/get", params: %{"name" => name}}

  defmodule CacheServer do
    @moduledoc "Kernel test fixture: server default cache_meta vs. per-resource overrides."

    use MCP.Server,
      name: "cache-server",
      version: "1.0.0",
      resources: [BareResource, OverriddenTtlResource, OverriddenScopeResource],
      resource_templates: [TitledTemplate, BareTemplate],
      list_cache: [ttl_ms: 1_000, cache_scope: "private"]
  end

  defp read_request(uri),
    do: %MCP.RPC.Request{id: 1, method: "resources/read", params: %{"uri" => uri}}

  @ctx %MCP.Context{principal: "test-principal", scopes: []}

  describe "validate_cache_scope!/1" do
    test "accepts the two scopes the spec defines" do
      assert MCP.Server.validate_cache_scope!("public") == "public"
      assert MCP.Server.validate_cache_scope!("private") == "private"
    end

    test "rejects anything else at compile time" do
      assert_raise ArgumentError, ~r/cache_scope/, fn ->
        MCP.Server.validate_cache_scope!("client")
      end
    end
  end

  describe "advertised capabilities" do
    test "a server declares only the features it actually registered" do
      capabilities = MCP.TestSupport.TestServer.discover_payload()["capabilities"]

      assert capabilities == %{
               "tools" => %{"listChanged" => false},
               "resources" => %{"listChanged" => false, "subscribe" => false},
               "prompts" => %{"listChanged" => false}
             }
    end

    test "a server with nothing registered advertises nothing" do
      assert MCP.TestSupport.BareServer.discover_payload()["capabilities"] == %{}
    end
  end

  describe "server metadata" do
    test "cache_meta/0 carries both required CacheableResult fields" do
      assert MCP.TestSupport.TestServer.cache_meta() ==
               %{"ttlMs" => 1234, "cacheScope" => "public"}
    end

    test "server_info/0 is the name and version given to `use`" do
      assert MCP.TestSupport.TestServer.server_info() ==
               %{"name" => "test-server", "version" => "9.9.9"}
    end
  end

  describe "title and annotations in list payloads" do
    test "build_entries! (tools) includes title and annotations when declared" do
      [entry] = MCP.Server.build_entries!([TitledTool])
      assert entry.payload["title"] == "Titled Tool"
      assert entry.payload["annotations"] == %{"readOnlyHint" => true}
    end

    test "build_entries! (tools) omits title and annotations when nil" do
      [entry] = MCP.Server.build_entries!([BareTool])
      refute Map.has_key?(entry.payload, "title")
      refute Map.has_key?(entry.payload, "annotations")
    end

    test "build_resource_entries! includes title and annotations when declared" do
      [entry] = MCP.Server.build_resource_entries!([TitledResource])
      assert entry.payload["title"] == "Titled Resource"
      assert entry.payload["annotations"] == %{"audience" => ["user"]}
    end

    test "build_resource_entries! omits title and annotations when nil" do
      [entry] = MCP.Server.build_resource_entries!([BareResource])
      refute Map.has_key?(entry.payload, "title")
      refute Map.has_key?(entry.payload, "annotations")
    end

    test "build_template_entries! includes title and annotations when declared" do
      [entry] = MCP.Server.build_template_entries!([TitledTemplate])
      assert entry.payload["title"] == "Titled Template"
      assert entry.payload["annotations"] == %{"audience" => ["assistant"]}
    end

    test "build_template_entries! omits title and annotations when nil" do
      [entry] = MCP.Server.build_template_entries!([BareTemplate])
      refute Map.has_key?(entry.payload, "title")
      refute Map.has_key?(entry.payload, "annotations")
    end

    test "build_prompt_entries! includes title when declared" do
      [entry] = MCP.Server.build_prompt_entries!([TitledPrompt])
      assert entry.payload["title"] == "Titled Prompt"
    end

    test "build_prompt_entries! omits title when nil" do
      [entry] = MCP.Server.build_prompt_entries!([BarePrompt])
      refute Map.has_key?(entry.payload, "title")
    end
  end

  describe "per-resource cache override" do
    test "build_resource_entries! computes a cache_override from declared cache_scope/ttl_ms" do
      [ttl_entry] = MCP.Server.build_resource_entries!([OverriddenTtlResource])
      assert ttl_entry.cache_override == %{"ttlMs" => 5_000}

      [scope_entry] = MCP.Server.build_resource_entries!([OverriddenScopeResource])
      assert scope_entry.cache_override == %{"cacheScope" => "public"}
    end

    test "build_resource_entries! yields an empty cache_override when neither is declared" do
      [entry] = MCP.Server.build_resource_entries!([BareResource])
      assert entry.cache_override == %{}
    end

    test "build_template_entries! computes a cache_override the same way" do
      [entry] = MCP.Server.build_template_entries!([TitledTemplate])
      assert entry.cache_override == %{"cacheScope" => "public", "ttlMs" => 9_000}

      [entry] = MCP.Server.build_template_entries!([BareTemplate])
      assert entry.cache_override == %{}
    end

    test "resources/read merges a resource's override on top of the server default" do
      {:ok, result} =
        MCP.Server.dispatch(CacheServer, read_request("servertest://overridden-ttl"), @ctx)

      # Only ttlMs is overridden; cacheScope still falls back to the server default.
      assert result["ttlMs"] == 5_000
      assert result["cacheScope"] == "private"
    end

    test "resources/read overriding only cacheScope leaves ttlMs at the server default" do
      {:ok, result} =
        MCP.Server.dispatch(CacheServer, read_request("servertest://overridden-scope"), @ctx)

      assert result["ttlMs"] == 1_000
      assert result["cacheScope"] == "public"
    end

    test "resources/read uses the server default outright when nothing is overridden" do
      {:ok, result} = MCP.Server.dispatch(CacheServer, read_request("servertest://bare"), @ctx)

      assert result["ttlMs"] == 1_000
      assert result["cacheScope"] == "private"
    end

    test "resources/read on a template applies the template's own override" do
      {:ok, result} =
        MCP.Server.dispatch(CacheServer, read_request("servertest://titled/42"), @ctx)

      assert result["ttlMs"] == 9_000
      assert result["cacheScope"] == "public"
    end
  end

  # The spec puts Annotations on the content block; Prompt itself has no such
  # field, so this is the only place audience/priority can attach to a prompt.
  describe "prompt message annotations" do
    test "a third tuple element becomes annotations on the content block" do
      {:ok, result} =
        MCP.Server.dispatch(PromptServer, get_prompt_request("annotated-prompt"), @ctx)

      assert [annotated, plain] = result["messages"]

      assert annotated == %{
               "role" => "user",
               "content" => %{
                 "type" => "text",
                 "text" => "for the model",
                 "annotations" => %{"audience" => ["assistant"], "priority" => 0.9}
               }
             }

      # A two-element message emits no annotations key at all.
      assert plain == %{
               "role" => "assistant",
               "content" => %{"type" => "text", "text" => "plain"}
             }
    end

    test "a bad annotation is refused rather than shipped unvalidated" do
      assert {:error, {code, _message, _data}} =
               MCP.Server.dispatch(
                 PromptServer,
                 get_prompt_request("bad-annotation-prompt"),
                 @ctx
               )

      assert code == MCP.RPC.internal_error()
    end
  end
end
