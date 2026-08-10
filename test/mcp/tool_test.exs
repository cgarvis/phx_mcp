defmodule MCP.ToolTest.ArrayTool do
  @moduledoc "Test fixture: array fields (items, max_items, enum, default) plus title/annotations."

  use MCP.Tool,
    name: "array_tool",
    scopes: [],
    title: "Array Tool",
    annotations: [read_only: true]

  @impl true
  def description, do: "Array field fixture"

  input do
    field :codes, :array, items: :string, max_items: 3, required: true, description: "Codes"

    field :status_filter, :array,
      items: :string,
      enum: ["optimal", "watch", "flagged", "recorded"]

    field :scores, :array, items: :integer, default: [1, 2]
  end

  @impl true
  def call(%__MODULE__{} = args, _ctx), do: {:ok, %{args: Map.from_struct(args)}}
end

defmodule MCP.ToolTest.DateTool do
  @moduledoc "Test fixture: :date fields, required, defaulted, and inside an array."

  use MCP.Tool, name: "date_tool", scopes: []

  @impl true
  def description, do: "Date field fixture"

  input do
    field :from, :date, required: true, description: "Window start"
    field :to, :date
    field :as_of, :date, default: ~D[2026-01-01]
    field :days, :array, items: :date
  end

  @impl true
  def call(%__MODULE__{} = args, _ctx), do: {:ok, %{from: args.from}}
end

defmodule MCP.ToolTest.BoundedTool do
  @moduledoc "Test fixture: numeric min/max on an integer and a number."

  use MCP.Tool, name: "bounded_tool", scopes: []

  @impl true
  def description, do: "Numeric bounds fixture"

  input do
    field :limit, :integer, min: 1, max: 50
    field :ratio, :number, min: 0, max: 1
  end

  @impl true
  def call(%__MODULE__{} = args, _ctx), do: {:ok, %{limit: args.limit}}
end

defmodule MCP.ToolTest do
  use ExUnit.Case, async: true

  alias MCP.TestSupport.EchoTool
  alias MCP.TestSupport.SecretTool
  alias MCP.ToolTest.ArrayTool

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

    # A dotted name serves fine but is silently dropped by Anthropic clients,
    # so compile time is the only place the mistake surfaces.
    test "a name with characters Anthropic clients reject is a compile-time error" do
      source = """
      defmodule MCP.ToolTest.DottedName do
        use MCP.Tool, name: "biomarkers.get", scopes: []
        @impl true
        def description, do: "dotted"
        @impl true
        def call(%__MODULE__{}, _ctx), do: {:ok, %{}}
      end
      """

      assert_raise ArgumentError, ~r/"biomarkers_get"/, fn -> Code.eval_string(source) end
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

  describe "date fields" do
    alias MCP.ToolTest.DateTool

    # "format" is what tells the model it is a day and not any old string.
    test "emits a string property carrying format: date" do
      properties = DateTool.input_schema()["properties"]

      assert properties["from"] == %{
               "type" => "string",
               "format" => "date",
               "description" => "Window start"
             }

      assert properties["days"] == %{
               "type" => "array",
               "items" => %{"type" => "string", "format" => "date"}
             }
    end

    # The whole point: call/2 gets a Date, so no tool parses one itself.
    test "a valid day reaches the struct as a Date" do
      assert {:ok, args} = MCP.Tool.validate_args(DateTool, %{"from" => "2026-08-07"})
      assert args.from == ~D[2026-08-07]
    end

    test "coerces every element of a date array" do
      args = %{"from" => "2026-08-07", "days" => ["2026-08-07", "2026-08-08"]}

      assert {:ok, validated} = MCP.Tool.validate_args(DateTool, args)
      assert validated.days == [~D[2026-08-07], ~D[2026-08-08]]
    end

    test "a malformed day is rejected before call/2" do
      assert {:error, [error]} = MCP.Tool.validate_args(DateTool, %{"from" => "not-a-date"})
      assert error =~ "from must be an ISO 8601 date"

      assert {:error, [error]} = MCP.Tool.validate_args(DateTool, %{"from" => "2026-02-30"})
      assert error =~ "from must be an ISO 8601 date"
    end

    test "a non-string day is rejected" do
      assert {:error, [error]} = MCP.Tool.validate_args(DateTool, %{"from" => 20_260_807})
      assert error =~ "from must be an ISO 8601 date"
    end

    test "a required date is still required" do
      assert {:error, ["from is required"]} = MCP.Tool.validate_args(DateTool, %{})
    end

    test "an omitted optional date is nil, and a default arrives as its Date" do
      assert {:ok, args} = MCP.Tool.validate_args(DateTool, %{"from" => "2026-08-07"})

      assert args.to == nil
      assert args.as_of == ~D[2026-01-01]
    end

    test "a default that is not a real day fails at compile time" do
      assert_raise ArgumentError, ~r/must be an ISO 8601 date/, fn ->
        MCP.Tool.__field__(:when, :date, default: "2026-13-01")
      end
    end
  end

  describe "numeric bounds" do
    test "min/max emit JSON Schema minimum/maximum" do
      schema = MCP.Tool.build_schema([MCP.Tool.__field__(:limit, :integer, min: 1, max: 50)])

      assert schema["properties"]["limit"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 50
             }
    end

    test "a value outside the bounds is rejected, inclusive at both ends" do
      alias MCP.ToolTest.BoundedTool

      assert {:error, ["limit must be at most 50"]} =
               MCP.Tool.validate_args(BoundedTool, %{"limit" => 51})

      assert {:error, ["limit must be at least 1"]} =
               MCP.Tool.validate_args(BoundedTool, %{"limit" => 0})

      assert {:ok, %{limit: 1}} = MCP.Tool.validate_args(BoundedTool, %{"limit" => 1})
      assert {:ok, %{limit: 50}} = MCP.Tool.validate_args(BoundedTool, %{"limit" => 50})
    end

    test "bounds work on :number too" do
      alias MCP.ToolTest.BoundedTool

      assert {:error, ["ratio must be at most 1"]} =
               MCP.Tool.validate_args(BoundedTool, %{"ratio" => 1.5})

      assert {:ok, %{ratio: 0.5}} = MCP.Tool.validate_args(BoundedTool, %{"ratio" => 0.5})
    end

    # A bound on a string would silently never be checked, so it is refused.
    test "bounds are refused on non-numeric types" do
      assert_raise ArgumentError, ~r/bounds apply to/, fn ->
        MCP.Tool.__field__(:name, :string, max: 10)
      end

      assert_raise ArgumentError, ~r/bounds apply to/, fn ->
        MCP.Tool.__field__(:codes, :array, items: :string, min: 1)
      end
    end

    test "a non-numeric bound, and an inverted pair, fail at compile time" do
      assert_raise ArgumentError, ~r/non-numeric max:/, fn ->
        MCP.Tool.__field__(:limit, :integer, max: "fifty")
      end

      assert_raise ArgumentError, ~r/admits nothing/, fn ->
        MCP.Tool.__field__(:limit, :integer, min: 50, max: 1)
      end
    end

    test "a default outside its own bounds fails at compile time" do
      assert_raise ArgumentError, ~r/must be at most 50/, fn ->
        MCP.Tool.__field__(:limit, :integer, max: 50, default: 100)
      end
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

  describe "array fields" do
    test "emit items, maxItems, description, and a nested items enum" do
      assert ArrayTool.input_schema() == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{
                 "codes" => %{
                   "type" => "array",
                   "items" => %{"type" => "string"},
                   "maxItems" => 3,
                   "description" => "Codes"
                 },
                 "status_filter" => %{
                   "type" => "array",
                   "items" => %{
                     "type" => "string",
                     "enum" => ["optimal", "watch", "flagged", "recorded"]
                   }
                 },
                 "scores" => %{
                   "type" => "array",
                   "items" => %{"type" => "integer"},
                   "default" => [1, 2]
                 }
               },
               "required" => ["codes"]
             }
    end
  end

  describe "validate_args/2 with array fields" do
    test "accepts a valid list" do
      assert {:ok, %ArrayTool{codes: ["a", "b"]}} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => ["a", "b"]})
    end

    test "rejects a non-list" do
      assert {:error, ["codes must be an array"]} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => "nope"})
    end

    test "rejects a list over max_items" do
      assert {:error, ["codes accepts at most 3 items"]} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => ["a", "b", "c", "d"]})
    end

    test "rejects a wrong element type" do
      assert {:error, ["codes items must be string"]} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => ["a", 1]})
    end

    test "rejects an element outside the item enum" do
      args = %{"codes" => ["a"], "status_filter" => ["nope"]}

      assert {:error, [error]} = MCP.Tool.validate_args(ArrayTool, args)
      assert error =~ "status_filter items must each be one of"
    end

    test "a required array field is still enforced" do
      assert {:error, ["codes is required"]} = MCP.Tool.validate_args(ArrayTool, %{})
    end

    test "an omitted optional array is nil" do
      assert {:ok, %ArrayTool{status_filter: nil}} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => ["a"]})
    end

    test "an array default lands in the struct" do
      assert {:ok, %ArrayTool{scores: [1, 2]}} =
               MCP.Tool.validate_args(ArrayTool, %{"codes" => ["a"]})
    end
  end

  describe "array field compile-time validation" do
    test ":array without items: raises" do
      assert_raise ArgumentError, ~r/is type :array and requires items:/, fn ->
        MCP.Tool.__field__(:codes, :array, [])
      end
    end

    test "items: on a non-array field raises" do
      assert_raise ArgumentError, ~r/declares items: but is not type :array/, fn ->
        MCP.Tool.__field__(:text, :string, items: :string)
      end
    end

    test "max_items: on a non-array field raises" do
      assert_raise ArgumentError, ~r/declares max_items: but is not type :array/, fn ->
        MCP.Tool.__field__(:text, :string, max_items: 3)
      end
    end

    test "an invalid items: type raises" do
      assert_raise ArgumentError, ~r/invalid items: :map/, fn ->
        MCP.Tool.__field__(:codes, :array, items: :map)
      end
    end
  end

  describe "title/0 and annotations/0" do
    test "return their declared values" do
      assert ArrayTool.title() == "Array Tool"
      assert ArrayTool.annotations() == %{"readOnlyHint" => true}
    end

    test "are nil when not declared" do
      assert EchoTool.title() == nil
      assert EchoTool.annotations() == nil
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
