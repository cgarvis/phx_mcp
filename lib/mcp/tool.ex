defmodule MCP.Tool do
  @moduledoc """
  Behaviour + DSL for MCP tools.

      defmodule MyApp.MCP.Tools.Greet do
        use MCP.Tool, name: "greet", scopes: ["profile:read"]

        @impl true
        def description, do: "Greet someone by name"

        input do
          field :name, :string, required: true, description: "Who to greet"
        end

        @impl true
        def call(%__MODULE__{name: name}, %MCP.Context{}), do: {:ok, %{greeting: "Hello " <> name}}
      end

  `input` fields support types `:string`, `:integer`, `:number`, `:boolean` and
  options `required:`, `enum:`, `description:`, `default:`. The same
  declarations emit the `inputSchema` JSON Schema map at compile time and drive
  argument validation before `call/2` is invoked — deliberately minimal, not
  full JSON Schema.

  The fields also define a struct on the tool module, and that struct — not a
  bare map — is what `call/2` receives. Matching `%__MODULE__{}` makes a
  misspelled argument a compile error rather than a clause that silently never
  matches. Required fields are in `@enforce_keys`.

  A `default:` is what makes a field optional, so it cannot be combined with
  `required: true`. It lands in two places from the one declaration: the
  schema's `default` annotation, so the model knows what omitting the field
  means, and the struct's own default, so omitting it actually produces that
  value. Both are needed — JSON Schema `default` is an annotation, and no
  validator is obliged to fill it in. A field with neither `required:` nor
  `default:` arrives as `nil` when omitted.

  An optional `output` block declares the result shape the same way:

      output do
        field :greeting, :string, required: true
      end

  It emits `outputSchema`, and every `{:ok, map}` is checked against it before
  it reaches the wire. Declaring it is a promise the spec enforces ("Servers
  MUST provide structured results that conform to this schema"), so a result
  that violates it is refused as an internal error rather than sent. That check
  is also what holds several `call/2` clauses to one shape. Tools that declare
  no `output` emit no `outputSchema` and are unconstrained.

  Return contract for `call/2` (and `resume/3` for multi round-trip tools):

    * `{:ok, map}` — completed result, conforming to `output` if declared
    * `{:input_required, requests, state}` — pause for client input; `requests`
      is a map of request name => request (see `MCP.Elicitation`), `state` is
      any term to restore on resume
    * `{:error, code, message}` — tool execution error (reported in-result with
      `isError: true`, not as a JSON-RPC error)
  """

  @type result ::
          {:ok, map()}
          | {:input_required, requests :: map(), state :: term()}
          | {:error, code :: String.t(), message :: String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback scopes() :: [String.t()]
  @callback input_schema() :: map()
  @callback output_schema() :: map() | nil
  @callback call(args :: struct(), MCP.Context.t()) :: result()
  @callback resume(state :: term(), input_responses :: map(), MCP.Context.t()) :: result()
  @optional_callbacks resume: 3

  @field_types [:string, :integer, :number, :boolean]

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    scopes = Keyword.get(opts, :scopes, [])

    quote do
      @behaviour MCP.Tool
      import MCP.Tool, only: [input: 1, output: 1], warn: false

      Module.register_attribute(__MODULE__, :mcp_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_output_fields, accumulate: true)
      @mcp_field_target nil
      @before_compile MCP.Tool

      @impl MCP.Tool
      def name, do: unquote(name)

      @impl MCP.Tool
      def scopes, do: unquote(scopes)
    end
  end

  defmacro input(do: block) do
    quote do
      # Re-importing MCP.Tool supersedes the :only from `use`, so restate it all.
      import MCP.Tool, only: [input: 1, output: 1, field: 2, field: 3], warn: false
      @mcp_field_target :mcp_fields
      unquote(block)
      @mcp_field_target nil
    end
  end

  defmacro output(do: block) do
    quote do
      # Re-importing MCP.Tool supersedes the :only from `use`, so restate it all.
      import MCP.Tool, only: [input: 1, output: 1, field: 2, field: 3], warn: false
      @mcp_field_target :mcp_output_fields
      unquote(block)
      @mcp_field_target nil
    end
  end

  # Which block is open decides which attribute this field lands in. The import
  # outlives the block, so a field written outside one has to be refused here.
  defmacro field(name, type, opts \\ []) do
    quote do
      Module.put_attribute(
        __MODULE__,
        MCP.Tool.__target__(@mcp_field_target, unquote(name)),
        MCP.Tool.__field__(unquote(name), unquote(type), unquote(opts))
      )
    end
  end

  @doc false
  def __target__(nil, name) do
    raise ArgumentError,
          "field #{inspect(name)} must be declared inside an input or output block"
  end

  def __target__(target, _name), do: target

  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:mcp_fields) |> Enum.reverse()
    output_fields = env.module |> Module.get_attribute(:mcp_output_fields) |> Enum.reverse()
    reject_output_defaults!(env.module, output_fields)

    schema = build_schema(fields)
    output_schema = if output_fields == [], do: nil, else: build_schema(output_fields)
    required = for {name, _type, opts} <- fields, opts[:required], do: name
    keys = struct_keys(fields)

    quote do
      def __mcp_fields__, do: unquote(Macro.escape(fields))
      def __mcp_output_fields__, do: unquote(Macro.escape(output_fields))

      @impl MCP.Tool
      def input_schema, do: unquote(Macro.escape(schema))

      @impl MCP.Tool
      def output_schema, do: unquote(Macro.escape(output_schema))

      # Injected last so handlers above can already match %__MODULE__{}.
      @enforce_keys unquote(required)
      defstruct unquote(Macro.escape(keys))
    end
  end

  # Nothing fills an output default, so it would only mislead the client.
  defp reject_output_defaults!(module, output_fields) do
    for {name, _type, opts} <- output_fields, Keyword.has_key?(opts, :default) do
      raise ArgumentError,
            "MCP.Tool output field #{inspect(name)} in #{inspect(module)} declares a default; " <>
              "defaults apply to input only"
    end
  end

  # defstruct wants bare atoms before {key, default} pairs.
  defp struct_keys(fields) do
    {defaulted, plain} =
      Enum.split_with(fields, fn {_name, _type, opts} -> Keyword.has_key?(opts, :default) end)

    Enum.map(plain, fn {name, _type, _opts} -> name end) ++
      Enum.map(defaulted, fn {name, _type, opts} -> {name, opts[:default]} end)
  end

  @doc false
  def __field__(name, type, opts) when is_atom(name) and type in @field_types do
    opts = Keyword.validate!(opts, [:required, :enum, :description, :default])
    validate_default!(name, type, opts)
    {name, type, opts}
  end

  def __field__(name, type, _opts) do
    raise ArgumentError,
          "invalid MCP.Tool field #{inspect(name)}: type #{inspect(type)} " <>
            "must be one of #{inspect(@field_types)}"
  end

  # A default is what makes a field optional, so the two are mutually exclusive.
  defp validate_default!(name, type, opts) do
    cond do
      not Keyword.has_key?(opts, :default) ->
        :ok

      opts[:required] ->
        raise ArgumentError,
              "MCP.Tool field #{inspect(name)} is both required and defaulted; " <>
                "a default makes the field optional"

      true ->
        case check_value(name, type, opts, opts[:default]) do
          :ok -> :ok
          {:error, message} -> raise ArgumentError, "invalid MCP.Tool default: #{message}"
        end
    end
  end

  @doc false
  def build_schema(fields) do
    properties =
      Map.new(fields, fn {name, type, opts} ->
        prop = %{"type" => json_type(type)}
        prop = maybe_put(prop, "description", opts[:description])
        prop = maybe_put(prop, "enum", opts[:enum])
        prop = maybe_put(prop, "default", opts[:default])
        {to_string(name), prop}
      end)

    required = for {name, _, opts} <- fields, opts[:required], do: to_string(name)

    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(&if required == [], do: &1, else: Map.put(&1, "required", required))
  end

  @doc """
  Validates string-keyed `args` against `module`'s declared fields.

  Checks type, required, and enum; rejects undeclared keys. Returns the
  tool's own struct, handed to `call/2` (keys come from the compile-time
  field list, never from input). Omitted optional fields are `nil`.
  """
  def validate_args(module, args) when is_atom(module) and is_map(args) do
    case validate_fields(module.__mcp_fields__(), args) do
      {:ok, validated} -> {:ok, struct!(module, validated)}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Checks a `call/2` result against `module`'s declared `output` fields.

  Returns `:ok` unchanged when the tool declares no output, since it then
  publishes no `outputSchema` to conform to. Result maps are conventionally
  atom-keyed, so keys are stringified before the same checks the input side
  runs: type, required, enum, and no undeclared keys.
  """
  def validate_result(module, result) when is_atom(module) and is_map(result) do
    case module.__mcp_output_fields__() do
      [] ->
        :ok

      fields ->
        stringified = Map.new(result, fn {key, value} -> {to_string(key), value} end)

        case validate_fields(fields, stringified) do
          {:ok, _validated} -> :ok
          {:error, errors} -> {:error, errors}
        end
    end
  end

  defp validate_fields(fields, args) do
    known = for {name, _, _} <- fields, do: to_string(name)

    unknown_errors =
      for key <- Map.keys(args), key not in known, do: "unknown field: #{inspect(key)}"

    {validated, field_errors} =
      Enum.reduce(fields, {%{}, []}, fn {name, type, opts}, {acc, errors} ->
        case Map.fetch(args, to_string(name)) do
          {:ok, value} ->
            case check_value(name, type, opts, value) do
              :ok -> {Map.put(acc, name, value), errors}
              {:error, message} -> {acc, [message | errors]}
            end

          :error ->
            if opts[:required] do
              {acc, ["#{name} is required" | errors]}
            else
              {acc, errors}
            end
        end
      end)

    case unknown_errors ++ Enum.reverse(field_errors) do
      [] -> {:ok, validated}
      errors -> {:error, errors}
    end
  end

  defp check_value(name, type, opts, value) do
    cond do
      not correct_type?(type, value) ->
        {:error, "#{name} must be a #{json_type(type)}"}

      is_list(opts[:enum]) and value not in opts[:enum] ->
        {:error, "#{name} must be one of #{inspect(opts[:enum])}"}

      true ->
        :ok
    end
  end

  defp correct_type?(:string, value), do: is_binary(value)
  defp correct_type?(:integer, value), do: is_integer(value)
  defp correct_type?(:number, value), do: is_number(value)
  defp correct_type?(:boolean, value), do: is_boolean(value)

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:number), do: "number"
  defp json_type(:boolean), do: "boolean"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
