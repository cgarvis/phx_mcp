defmodule MCP.ToolTest do
  use ExUnit.Case, async: true

  alias MCP.TestSupport.EchoTool
  alias MCP.TestSupport.SecretTool

  describe "schema emission" do
    test "emits a JSON Schema object from the field DSL" do
      assert EchoTool.input_schema() == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{
                 "text" => %{"type" => "string", "description" => "Text to echo"},
                 "count" => %{"type" => "integer"},
                 "level" => %{
                   "type" => "string",
                   "enum" => ["low", "high"],
                   "default" => "low"
                 },
                 "loud" => %{"type" => "boolean"}
               },
               "required" => ["text"]
             }
    end

    test "a tool without an input block gets an empty object schema" do
      assert SecretTool.input_schema() == %{
               "type" => "object",
               "properties" => %{},
               "additionalProperties" => false
             }
    end

    test "use options surface as name/scopes" do
      assert EchoTool.name() == "echo"
      assert SecretTool.scopes() == ["secret:read"]
    end
  end

  describe "generated struct" do
    test "the field DSL defines a struct on the tool module" do
      assert %EchoTool{text: "hi", count: nil, level: "low", loud: nil} = %EchoTool{text: "hi"}
    end

    test "a tool without an input block still gets a struct" do
      assert %SecretTool{} == struct!(SecretTool, %{})
    end

    test "required fields are enforced when building the struct" do
      assert_raise ArgumentError, ~r/must also be given when building struct/, fn ->
        struct!(EchoTool, %{count: 1})
      end
    end

    test "a misspelled field in a struct pattern is a compile-time error" do
      source = """
      defmodule MCP.ToolTest.Typo do
        use MCP.Tool, name: "typo", scopes: []
        @impl true
        def description, do: "typo"
        input do
          field :text, :string, required: true
        end
        @impl true
        def call(%__MODULE__{tekst: t}, _ctx), do: {:ok, %{t: t}}
      end
      """

      {_result, diagnostics} = Code.with_diagnostics(fn -> Code.eval_string(source) end)

      assert Enum.any?(diagnostics, fn d ->
               d.severity == :error and d.message =~ "unknown key :tekst"
             end)
    end
  end

  describe "validate_args/2" do
    test "returns the tool struct built from the validated values" do
      args = %{"text" => "hi", "count" => 2, "level" => "low", "loud" => true}

      assert MCP.Tool.validate_args(EchoTool, args) ==
               {:ok, %EchoTool{text: "hi", count: 2, level: "low", loud: true}}
    end

    test "an omitted field is its default, or nil when it declares none" do
      assert MCP.Tool.validate_args(EchoTool, %{"text" => "hi"}) ==
               {:ok, %EchoTool{text: "hi", count: nil, level: "low", loud: nil}}
    end

    test "a supplied value wins over the default" do
      assert {:ok, %EchoTool{level: "high"}} =
               MCP.Tool.validate_args(EchoTool, %{"text" => "hi", "level" => "high"})
    end

    test "missing required field" do
      assert {:error, ["text is required"]} = MCP.Tool.validate_args(EchoTool, %{})
    end

    test "wrong types" do
      args = %{"text" => 1, "count" => "x", "loud" => "yes"}
      assert {:error, errors} = MCP.Tool.validate_args(EchoTool, args)

      assert "text must be a string" in errors
      assert "count must be a integer" in errors
      assert "loud must be a boolean" in errors
    end

    test "enum violation" do
      args = %{"text" => "hi", "level" => "mid"}

      assert {:error, [error]} = MCP.Tool.validate_args(EchoTool, args)
      assert error =~ "level must be one of"
    end

    test "undeclared keys are rejected" do
      args = %{"text" => "hi", "sneaky" => true}

      assert {:error, [error]} = MCP.Tool.validate_args(EchoTool, args)
      assert error =~ "unknown field"
    end
  end

  describe "defaults" do
    test "a default makes the field optional, so it cannot also be required" do
      assert_raise ArgumentError, ~r/both required and defaulted/, fn ->
        MCP.Tool.__field__(:text, :string, required: true, default: "x")
      end
    end

    test "a default is checked against its own type and enum" do
      assert_raise ArgumentError, ~r/must be a string/, fn ->
        MCP.Tool.__field__(:text, :string, default: 42)
      end

      assert_raise ArgumentError, ~r/must be one of/, fn ->
        MCP.Tool.__field__(:level, :string, enum: ["low"], default: "mid")
      end
    end

    test "a defaulted field is not listed as required in the schema" do
      schema = MCP.Tool.build_schema([MCP.Tool.__field__(:level, :string, default: "low")])

      refute Map.has_key?(schema, "required")
      assert schema["properties"]["level"]["default"] == "low"
    end

    test "false is a usable boolean default" do
      schema = MCP.Tool.build_schema([MCP.Tool.__field__(:loud, :boolean, default: false)])

      assert schema["properties"]["loud"]["default"] == false
    end
  end

  describe "output schema" do
    test "the output block emits a schema, and no block emits none" do
      assert SecretTool.output_schema() == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{"secret" => %{"type" => "string"}},
               "required" => ["secret"]
             }

      assert EchoTool.output_schema() == nil
    end

    test "a tool declaring no output constrains nothing" do
      assert MCP.Tool.validate_result(EchoTool, %{anything: [1, 2, 3]}) == :ok
    end

    test "a conforming result passes, whatever the key type" do
      assert MCP.Tool.validate_result(SecretTool, %{secret: "s3kr3t"}) == :ok
      assert MCP.Tool.validate_result(SecretTool, %{"secret" => "s3kr3t"}) == :ok
    end

    test "flags a wrong type, a missing field, and an undeclared one" do
      assert {:error, ["secret must be a string"]} =
               MCP.Tool.validate_result(SecretTool, %{secret: 42})

      assert {:error, ["secret is required"]} = MCP.Tool.validate_result(SecretTool, %{})

      assert {:error, [error]} =
               MCP.Tool.validate_result(SecretTool, %{secret: "s", extra: "x"})

      assert error =~ "unknown field"
    end

    test "an output field cannot declare a default" do
      source = """
      defmodule MCP.ToolTest.OutputDefault do
        use MCP.Tool, name: "output_default", scopes: []
        @impl true
        def description, do: "nope"
        output do
          field :status, :string, default: "ok"
        end
        @impl true
        def call(_args, _ctx), do: {:ok, %{status: "ok"}}
      end
      """

      assert_raise ArgumentError, ~r/defaults apply to input only/, fn ->
        Code.eval_string(source)
      end
    end
  end

  # The import outlives the block, so a stray field would silently land in
  # whichever attribute the last block happened to leave open.
  test "a field outside an input or output block is rejected" do
    source = """
    defmodule MCP.ToolTest.StrayField do
      use MCP.Tool, name: "stray", scopes: []
      @impl true
      def description, do: "nope"
      output do
        field :status, :string
      end
      field :leaked, :string
      @impl true
      def call(_args, _ctx), do: {:ok, %{status: "ok"}}
    end
    """

    assert_raise ArgumentError, ~r/must be declared inside an input or output block/, fn ->
      Code.eval_string(source)
    end
  end

  test "field rejects unsupported types at compile time" do
    assert_raise ArgumentError, ~r/must be one of/, fn ->
      MCP.Tool.__field__(:bad, :map, [])
    end
  end
end
