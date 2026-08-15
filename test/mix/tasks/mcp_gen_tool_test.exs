defmodule Mix.Tasks.Mcp.Gen.ToolTest do
  # Not async: the task writes files and reads Mix.shell().
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduledoc false

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp_gen_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp generate(dir, module, args) do
    capture_io(fn ->
      Mix.Tasks.Mcp.Gen.Tool.run(args ++ ["--dir", dir, "--module", module])
    end)
  end

  defp only_file(dir) do
    [path] = Path.wildcard(Path.join(dir, "**/*.ex"))
    File.read!(path)
  end

  # The point of the generator is that what it writes compiles as a real tool,
  # so the assertions go through the compiler rather than over the string.
  defp compile!(source) do
    [{module, _bytecode} | _rest] = Code.compile_string(source)
    module
  end

  describe "generated module" do
    test "compiles into a working MCP.Tool", %{dir: dir} do
      generate(dir, "GenTest.Basic", [
        "Orders.Get",
        "orders_get",
        "order_id:string:required",
        "limit:integer",
        "--scope",
        "orders:read"
      ])

      module = dir |> only_file() |> compile!()

      assert module.name() == "orders_get"
      assert module.scopes() == ["orders:read"]
      assert module.title() == "Orders Get"
      assert is_binary(module.description())

      schema = module.input_schema()
      assert schema["properties"]["order_id"]["type"] == "string"
      assert schema["properties"]["limit"]["type"] == "integer"
      assert schema["required"] == ["order_id"]
    end

    test "validates arguments through the same path MCP.Server uses", %{dir: dir} do
      generate(dir, "GenTest.Validated", ["Orders.Get", "orders_get", "order_id:string:required"])

      module = dir |> only_file() |> compile!()

      assert {:ok, %{order_id: "abc"}} = MCP.Tool.validate_args(module, %{"order_id" => "abc"})
      assert {:error, _reason} = MCP.Tool.validate_args(module, %{})
    end

    test "call/2 stub returns a well-formed error rather than raising", %{dir: dir} do
      generate(dir, "GenTest.Stub", ["Orders.Get", "orders_get", "order_id:string:required"])

      module = dir |> only_file() |> compile!()
      args = struct(module, order_id: "abc")

      assert {:error, "not_implemented", message} =
               module.call(args, %MCP.Context{assigns: %{scope: :ignored}})

      assert message =~ "orders_get"
    end

    test "compiles with no fields at all", %{dir: dir} do
      generate(dir, "GenTest.NoFields", ["Health.Ping", "health_ping"])

      module = dir |> only_file() |> compile!()

      assert module.input_schema()["properties"] == %{}

      assert module.call(struct(module), %MCP.Context{assigns: %{scope: nil}}) |> elem(0) ==
               :error
    end

    test "accepts every field type the DSL supports", %{dir: dir} do
      generate(dir, "GenTest.AllTypes", [
        "Kitchen.Sink",
        "kitchen_sink",
        "a:string",
        "b:integer",
        "c:number",
        "d:boolean",
        "e:date",
        "f:array:string"
      ])

      properties = dir |> only_file() |> compile!() |> then(& &1.input_schema()["properties"])

      assert Map.keys(properties) |> Enum.sort() == ~w(a b c d e f)
      assert properties["f"]["type"] == "array"
      assert properties["f"]["items"]["type"] == "string"
    end

    test "emits items: on an array field", %{dir: dir} do
      generate(dir, "GenTest.Array", [
        "Labs.History",
        "labs_history",
        "codes:array:string:required"
      ])

      source = only_file(dir)
      assert source =~ "field :codes, :array, items: :string, required: true"

      module = compile!(source)
      assert module.input_schema()["required"] == ["codes"]
    end
  end

  describe "validation" do
    test "rejects a dotted tool name before writing anything", %{dir: dir} do
      assert_raise ArgumentError, ~r/biomarkers\.get/, fn ->
        generate(dir, "GenTest.Dotted", ["Biomarkers.Get", "biomarkers.get"])
      end

      assert Path.wildcard(Path.join(dir, "**/*.ex")) == []
    end

    test "rejects an unknown field type", %{dir: dir} do
      assert_raise Mix.Error, ~r/invalid field/, fn ->
        generate(dir, "GenTest.BadType", ["Orders.Get", "orders_get", "order_id:uuid"])
      end
    end

    test "rejects an array with no element type", %{dir: dir} do
      assert_raise Mix.Error, ~r/invalid field/, fn ->
        generate(dir, "GenTest.BareArray", ["Orders.Get", "orders_get", "codes:array"])
      end
    end

    test "rejects an array whose element type is itself an array", %{dir: dir} do
      assert_raise Mix.Error, ~r/invalid field/, fn ->
        generate(dir, "GenTest.NestedArray", ["Orders.Get", "orders_get", "codes:array:array"])
      end
    end

    test "rejects a malformed field spec", %{dir: dir} do
      assert_raise Mix.Error, ~r/invalid field/, fn ->
        generate(dir, "GenTest.BadSpec", ["Orders.Get", "orders_get", "order_id"])
      end
    end

    test "requires a module suffix and a tool name", %{dir: dir} do
      assert_raise Mix.Error, ~r/module suffix and a tool name/, fn ->
        generate(dir, "GenTest.TooFew", ["OnlyOne"])
      end
    end
  end

  describe "output" do
    test "warns when the tool declares no scopes", %{dir: dir} do
      output = generate(dir, "GenTest.Scopeless", ["Orders.Get", "orders_get"])

      assert output =~ "declares no scopes"
    end

    test "stays quiet about scopes when one is given", %{dir: dir} do
      output = generate(dir, "GenTest.Scoped", ["Orders.Get", "orders_get", "--scope", "o:read"])

      refute output =~ "declares no scopes"
    end

    test "names the module to register on the server", %{dir: dir} do
      output = generate(dir, "GenTest.NextSteps", ["Orders.Get", "orders_get"])

      assert output =~ "use MCP.Server"
      assert output =~ "GenTest.NextSteps"
    end

    test "writes the file at a path derived from the module suffix", %{dir: dir} do
      generate(dir, "GenTest.Path", ["Orders.Get", "orders_get"])

      assert [path] = Path.wildcard(Path.join(dir, "**/*.ex"))
      assert Path.relative_to(path, dir) == "orders/get.ex"
    end
  end

  describe "formatting" do
    test "generated source is already formatted", %{dir: dir} do
      generate(dir, "GenTest.Formatted", [
        "Orders.Get",
        "orders_get",
        "order_id:string:required",
        "--scope",
        "orders:read"
      ])

      source = only_file(dir)

      # The DSL's own locals_without_parens, which is what the library exports
      # for consumers, so a generated file must survive the host's `mix format`.
      formatted =
        Code.format_string!(source, locals_without_parens: [field: 2, field: 3, input: 1])
        |> IO.iodata_to_binary()
        |> Kernel.<>("\n")

      assert formatted == source
    end
  end
end
