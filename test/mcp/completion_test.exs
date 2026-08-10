defmodule MCP.CompletionTest do
  use ExUnit.Case, async: true

  defmodule CodeTemplate do
    @moduledoc false

    use MCP.ResourceTemplate,
      uri_template: "moxie://member/biomarkers/{code}",
      name: "biomarker",
      scopes: []

    @impl true
    def description, do: "A biomarker by code"

    @impl true
    def read(_uri, %__MODULE__{code: code}, _ctx), do: {:ok, %{code: code}}

    @impl true
    def complete("code", value, _ctx) do
      {:ok, Enum.filter(["apob", "apoa1", "ldl", "hdl"], &String.starts_with?(&1, value))}
    end
  end

  defmodule ExplainPrompt do
    @moduledoc false

    use MCP.Prompt, name: "explain_biomarker", scopes: []

    @impl true
    def description, do: "Explain a biomarker"

    arguments do
      field :code, :string, required: true
    end

    @impl true
    def get(%__MODULE__{code: code}, _ctx), do: {:ok, [{:user, "Explain #{code}"}]}

    @impl true
    def complete("code", value, _ctx) do
      {:ok, Enum.filter(["apob", "apoa1", "ldl", "hdl"], &String.starts_with?(&1, value))}
    end
  end

  defmodule PlainTemplate do
    @moduledoc false

    use MCP.ResourceTemplate, uri_template: "moxie://plain/{id}", name: "plain", scopes: []

    @impl true
    def description, do: "No complete/3 here"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}
  end

  defmodule SecretTemplate do
    @moduledoc false

    use MCP.ResourceTemplate,
      uri_template: "moxie://secret/{id}",
      name: "secret",
      scopes: ["secret:read"]

    @impl true
    def description, do: "Gated behind a scope the test ctx lacks by default"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}

    @impl true
    def complete("id", value, _ctx) do
      {:ok, Enum.filter(["x1", "x2"], &String.starts_with?(&1, value))}
    end
  end

  defmodule ManyValuesTemplate do
    @moduledoc false

    use MCP.ResourceTemplate, uri_template: "moxie://many/{id}", name: "many", scopes: []

    @impl true
    def description, do: "Returns more than the 100-value truncation cap"

    @impl true
    def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, %{id: id}}

    @impl true
    def complete("id", _value, _ctx), do: {:ok, Enum.map(1..150, &"item#{&1}")}
  end

  defmodule Server do
    @moduledoc false

    use MCP.Server,
      name: "completion-server",
      version: "1.0.0",
      resource_templates: [CodeTemplate, PlainTemplate, SecretTemplate, ManyValuesTemplate],
      prompts: [ExplainPrompt]
  end

  defmodule NoCompletionsServer do
    @moduledoc false

    use MCP.Server,
      name: "no-completions-server",
      version: "1.0.0",
      resource_templates: [PlainTemplate]
  end

  @ctx %MCP.Context{principal: "test-principal", scopes: []}
  @secret_ctx %MCP.Context{principal: "test-principal", scopes: ["secret:read"]}

  defp request(ref, argument) do
    %MCP.RPC.Request{
      id: 1,
      method: "completion/complete",
      params: %{"ref" => ref, "argument" => argument}
    }
  end

  defp dispatch(ref, argument, ctx \\ @ctx) do
    MCP.Server.dispatch(Server, request(ref, argument), ctx)
  end

  describe "completion/complete" do
    test "a template completion returns filtered values" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://member/biomarkers/{code}"}
      {:ok, result} = dispatch(ref, %{"name" => "code", "value" => "apo"})

      assert result["resultType"] == "complete"

      assert result["completion"] == %{
               "values" => ["apob", "apoa1"],
               "total" => 2,
               "hasMore" => false
             }
    end

    test "a prompt completion works" do
      ref = %{"type" => "ref/prompt", "name" => "explain_biomarker"}
      {:ok, result} = dispatch(ref, %{"name" => "code", "value" => "ldl"})

      assert result["completion"] == %{"values" => ["ldl"], "total" => 1, "hasMore" => false}
    end

    test "truncates to 100 values and reports hasMore" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://many/{id}"}
      {:ok, result} = dispatch(ref, %{"name" => "id", "value" => ""})

      assert length(result["completion"]["values"]) == 100
      assert result["completion"]["total"] == 100
      assert result["completion"]["hasMore"] == true
    end

    test "an out-of-scope template returns an empty completion, not an error" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://secret/{id}"}
      {:ok, result} = dispatch(ref, %{"name" => "id", "value" => "x"})

      assert result["completion"] == %{"values" => [], "total" => 0, "hasMore" => false}
    end

    test "the same ref completes once the caller actually has the scope" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://secret/{id}"}
      {:ok, result} = dispatch(ref, %{"name" => "id", "value" => "x"}, @secret_ctx)

      assert result["completion"]["values"] == ["x1", "x2"]
    end

    test "a template without complete/3 returns an empty completion" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://plain/{id}"}
      {:ok, result} = dispatch(ref, %{"name" => "id", "value" => "x"})

      assert result["completion"] == %{"values" => [], "total" => 0, "hasMore" => false}
    end

    test "a uri matching no registered template returns an empty completion" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://nope/{id}"}
      {:ok, result} = dispatch(ref, %{"name" => "id", "value" => ""})

      assert result["completion"] == %{"values" => [], "total" => 0, "hasMore" => false}
    end

    test "a prompt name matching nothing registered returns an empty completion" do
      ref = %{"type" => "ref/prompt", "name" => "nope"}
      {:ok, result} = dispatch(ref, %{"name" => "code", "value" => ""})

      assert result["completion"] == %{"values" => [], "total" => 0, "hasMore" => false}
    end

    test "a missing argument.value defaults to an empty-prefix completion" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://member/biomarkers/{code}"}
      {:ok, result} = dispatch(ref, %{"name" => "code"})

      assert result["completion"]["values"] == ["apob", "apoa1", "ldl", "hdl"]
    end
  end

  describe "malformed params" do
    test "a missing ref.type is invalid_params" do
      ref = %{"uri" => "moxie://member/biomarkers/{code}"}
      {:error, {code, _message, _data}} = dispatch(ref, %{"name" => "code"})

      assert code == MCP.RPC.invalid_params()
    end

    test "a non-string ref.type is invalid_params" do
      ref = %{"type" => 123, "uri" => "moxie://member/biomarkers/{code}"}
      {:error, {code, _message, _data}} = dispatch(ref, %{"name" => "code"})

      assert code == MCP.RPC.invalid_params()
    end

    test "a missing argument.name is invalid_params" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://member/biomarkers/{code}"}
      {:error, {code, _message, _data}} = dispatch(ref, %{})

      assert code == MCP.RPC.invalid_params()
    end

    test "a non-string argument.value is invalid_params" do
      ref = %{"type" => "ref/resource", "uri" => "moxie://member/biomarkers/{code}"}
      {:error, {code, _message, _data}} = dispatch(ref, %{"name" => "code", "value" => 42})

      assert code == MCP.RPC.invalid_params()
    end

    test "an unrecognized ref type is invalid_params" do
      ref = %{"type" => "ref/tool", "name" => "whatever"}
      {:error, {code, _message, _data}} = dispatch(ref, %{"name" => "code"})

      assert code == MCP.RPC.invalid_params()
    end
  end

  describe "advertised completions capability" do
    test "present when at least one template or prompt exports complete/3" do
      assert Server.discover_payload()["capabilities"]["completions"] == %{}
    end

    test "absent when nothing exports complete/3" do
      refute Map.has_key?(NoCompletionsServer.discover_payload()["capabilities"], "completions")
    end
  end
end
