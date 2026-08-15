defmodule Mix.Tasks.Mcp.Gen.Tool do
  @shortdoc "Generates an MCP tool module"

  @moduledoc """
  Generates an `MCP.Tool` module, its input block, and a `call/2` stub.

      mix mcp.gen.tool Orders.Get orders_get order_id:string:required status:string

  The first argument is the module suffix, the second is the tool name the
  client sees, and the rest are input fields as `name:type` or
  `name:type:required`.

  ## Why `mcp.gen.tool` and not `phx.gen.mcp_tool`

  A task's name is its module path lowercased, so `phx.gen.*` would mean
  defining `Mix.Tasks.Phx.Gen.*` — squatting inside Phoenix's namespace, where
  it would list in `mix help` as though it were official and break the day
  Phoenix ships the same name. Tasks belong under the library that owns them.

  ## Where the file lands

  Derived from the host app: `lib/<app>_web/mcp/tools/` when a web directory
  exists, otherwise `lib/<app>/mcp/tools/`. Override with `--module` or
  `--dir`.

  ## Field types

  `string`, `integer`, `number`, `boolean`, `date`, and `array:<element_type>`.
  A field is optional unless the spec ends in `:required`:

      order_id:string:required
      limit:integer
      codes:array:string:required

  An array carries its element type because `MCP.Tool` requires `items:` to
  type-check elements. Anything richer (`enum:`, `min:`, `max:`, `max_items:`,
  `default:`) is a one-line edit afterwards; see `MCP.Tool`.

  ## Options

    * `--scope` — a scope the caller must hold. Repeatable. A tool with no
      scope is callable by anyone who can reach the endpoint, so the generated
      module declares one and the task warns when you omit it.
    * `--title` — human-facing title. Defaults to a title-cased tool name.
    * `--module` — full module name, bypassing derivation.
    * `--dir` — output directory, bypassing derivation.

  ## Example

      $ mix mcp.gen.tool Orders.Get orders_get order_id:string:required \\
          --scope orders:read

      * creating lib/my_app_web/mcp/tools/orders/get.ex

      Add the tool to your MCP.Server:

          use MCP.Server,
            tools: [
              MyAppWeb.MCP.Tools.Orders.Get
            ]
  """

  use Mix.Task

  @switches [scope: :keep, title: :string, module: :string, dir: :string]
  @scalar_types ~w(string integer number boolean date)

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    {suffix, tool_name, field_args} = parse_positional(positional)
    fields = Enum.map(field_args, &parse_field/1)
    scopes = Keyword.get_values(opts, :scope)

    # MCP.Name is the same check `use MCP.Tool` applies at compile time. Running
    # it here turns a dotted name into an error now rather than a tool that
    # compiles, serves, and is silently dropped by the client.
    MCP.Name.validate!(tool_name, "MCP.Tool")

    module = normalize_module(opts[:module]) || derive_module(suffix)
    path = Path.join(opts[:dir] || derive_dir(), Macro.underscore(suffix) <> ".ex")

    contents = render(module, tool_name, opts[:title] || titleize(tool_name), scopes, fields)

    create_file(path, contents)
    print_next_steps(module, scopes)
  end

  ## Parsing

  defp parse_positional([suffix, tool_name | fields]), do: {suffix, tool_name, fields}

  defp parse_positional(_args) do
    Mix.raise("""
    expected at least a module suffix and a tool name, for example:

        mix mcp.gen.tool Orders.Get orders_get order_id:string:required
    """)
  end

  # An :array field is nothing without items:, which is how MCP.Tool type-checks
  # its elements, so the element type is part of the spec rather than a TODO.
  defp parse_field(spec) do
    case String.split(spec, ":") do
      [name, "array", items] when items in @scalar_types ->
        {name, "array", items, false}

      [name, "array", items, "required"] when items in @scalar_types ->
        {name, "array", items, true}

      [name, type] when type in @scalar_types ->
        {name, type, nil, false}

      [name, type, "required"] when type in @scalar_types ->
        {name, type, nil, true}

      _bad ->
        Mix.raise("""
        invalid field #{inspect(spec)}.

        Expected one of:

            name:type
            name:type:required
            name:array:element_type
            name:array:element_type:required

        where type and element_type are one of: #{Enum.join(@scalar_types, ", ")}
        """)
    end
  end

  ## Derivation

  # `--module` arrives as a string; the derived name is already a module atom.
  # Both have to reach the template the same way, since it renders with
  # `inspect/1` and a string would render quoted into `defmodule`.
  defp normalize_module(nil), do: nil
  defp normalize_module(name) when is_binary(name), do: Module.concat([name])

  defp derive_module(suffix), do: Module.concat([base_namespace(), "MCP", "Tools", suffix])

  # A tool reads request-scoped data and shapes a response, so it belongs on the
  # web side of an app that has one, next to the other things that serve.
  defp base_namespace do
    app =
      Mix.Project.config()[:app] || Mix.raise("mix mcp.gen.tool must run inside a Mix project")

    base = app |> to_string() |> Macro.camelize()

    if File.dir?(Path.join("lib", "#{app}_web")), do: base <> "Web", else: base
  end

  defp derive_dir do
    app = Mix.Project.config()[:app]
    web = Path.join("lib", "#{app}_web")
    root = if File.dir?(web), do: web, else: Path.join("lib", to_string(app))

    Path.join([root, "mcp", "tools"])
  end

  defp titleize(tool_name) do
    tool_name |> String.split(["_", "-"]) |> Enum.map_join(" ", &String.capitalize/1)
  end

  ## Rendering

  defp render(module, tool_name, title, scopes, fields) do
    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      `#{tool_name}` -- TODO: what this returns, and what it deliberately does not.
      \"\"\"

      use MCP.Tool,
        name: #{inspect(tool_name)},
        scopes: #{inspect(scopes)},
        title: #{inspect(title)},
        annotations: [read_only: true, open_world: false]

      @impl true
      def description,
        do: "TODO: one sentence. The model reads this to decide whether to call the tool."

    #{render_input(fields)}
      @impl true
      def call(%__MODULE__{}#{render_args_binding(fields)}, %MCP.Context{assigns: %{scope: _scope}}) do
        {:error, "not_implemented", "#{tool_name} is not implemented yet"}
      end
    end
    """
  end

  defp render_input([]) do
    """
      # No arguments. Delete this comment, or add an input block:
      #
      #     input do
      #       field :query, :string, required: true, description: "..."
      #     end
    """
  end

  defp render_input(fields) do
    body = Enum.map_join(fields, "\n", &render_field/1)

    """
      input do
    #{body}
      end
    """
  end

  defp render_field({name, type, items, required?}) do
    opts =
      [items && "items: :#{items}", required? && "required: true", ~s(description: "TODO")]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    ~s(    field :#{name}, :#{type}, #{opts})
  end

  # Underscored because the stub body uses neither binding, and a host that
  # compiles with --warnings-as-errors would fail on a freshly generated file.
  # Dropping the underscore is the first edit anyone makes here.
  defp render_args_binding([]), do: ""
  defp render_args_binding(_fields), do: " = _args"

  ## Output

  defp create_file(path, contents) do
    if File.exists?(path) and not Mix.shell().yes?("#{path} already exists. Overwrite?") do
      Mix.raise("aborted")
    end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    Mix.shell().info([:green, "* creating ", :reset, path])
  end

  defp print_next_steps(module, scopes) do
    Mix.shell().info("""

    Add the tool to your MCP.Server:

        use MCP.Server,
          tools: [
            #{inspect(module)}
          ]
    """)

    if scopes == [] do
      Mix.shell().info([
        :yellow,
        "warning: ",
        :reset,
        "the tool declares no scopes, so tools/list exposes it to anonymous\n",
        "callers and anyone who can reach the endpoint can call it. Pass --scope\n",
        "unless that is what you want.\n"
      ])
    end
  end
end
