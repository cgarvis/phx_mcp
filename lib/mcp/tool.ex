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

  `input` fields support types `:string`, `:integer`, `:number`, `:boolean`,
  `:date`, `:array` and options `required:`, `enum:`, `description:`,
  `default:`. `:integer` and `:number` additionally take `min:`/`max:`, which
  emit JSON Schema's `minimum`/`maximum` and are enforced before `call/2`, so
  a bound never has to be restated in a tool body. A `:date` is a string on
  the wire, emitted as
  `{"type": "string", "format": "date"}` and parsed before `call/2`, which
  receives a `%Date{}` — so no tool re-parses one, and a malformed day is a
  -32602 like any other bad argument rather than a per-tool error branch. An
  `:array` field also takes `items:` (required — the element type, one of the
  four scalars) and `max_items:` (optional). `enum:` on an array field
  constrains each element, not the list itself, so the schema nests it inside
  the array's `items` sub-schema rather than on the property. The same
  declarations emit the `inputSchema` JSON Schema map at compile time and
  drive argument validation before `call/2` is invoked — deliberately
  minimal, not full JSON Schema.

  `use MCP.Tool` also takes optional `title:` (a short display label, for
  clients that show one instead of `name`) and `annotations:`, a keyword list
  of behaviour hints validated by `MCP.Annotations`:

      annotations: [read_only: true, open_world: false]

  Both are `nil` when not declared.

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
    * `{:ok, map, resource_links}` — the same result, plus pointers to
      resources this server also serves (see below)
    * `{:input_required, requests, state}` — pause for client input; `requests`
      is a map of request name => request (see `MCP.Elicitation`), `state` is
      any term to restore on resume
    * `{:error, code, message}` — tool execution error (reported in-result with
      `isError: true`, not as a JSON-RPC error)

  ## Resource links

  A tool that finds things can hand back the resources those things are, so
  the client can read each one with `resources/read`:

      def call(%__MODULE__{query: query}, %MCP.Context{assigns: %{scope: scope}}) do
        orders = MyApp.Orders.search(scope, query)

        links =
          for order <- orders do
            %{
              uri: "myapp://orders/\#{order.id}",
              name: "order-\#{order.id}",
              title: "Order \#\#{order.id}",
              mime_type: "application/json"
            }
          end

        {:ok, %{count: length(orders)}, links}
      end

  Each link is validated by `MCP.ResourceLink` (which is also where the
  accepted keys are documented) and emitted as a `resource_link` content block
  after the result's text block, in the order the tool returned them.
  `structuredContent` is untouched: it is still exactly the map, and an
  `output` block still constrains exactly that map and nothing else. A link
  that fails validation is the tool's own bug, so it is refused as an internal
  error rather than sent malformed — the same treatment a result violating its
  `outputSchema` gets. A `{:error, code, message}` carries no links.

  The links ride in `content` rather than in `structuredContent` because
  `resource_link` is the protocol's own way of saying "this is a resource you
  can read": a client renders one and follows it knowing nothing about this
  server. A URI in structured output is just a string, and every client would
  need a per-server convention to learn that this particular field is
  fetchable and that one is not.
  """

  @type result ::
          {:ok, map()}
          | {:ok, map(), [MCP.ResourceLink.link()]}
          | {:input_required, requests :: map(), state :: term()}
          | {:error, code :: String.t(), message :: String.t()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback scopes() :: [String.t()]
  @callback title() :: String.t() | nil
  @callback annotations() :: map() | nil
  @callback input_schema() :: map()
  @callback output_schema() :: map() | nil
  @callback call(args :: struct(), MCP.Context.t()) :: result()
  @callback resume(state :: term(), input_responses :: map(), MCP.Context.t()) :: result()
  @optional_callbacks resume: 3

  @scalar_types [:string, :integer, :number, :boolean, :date]
  @field_types @scalar_types ++ [:array]

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    scopes = Keyword.get(opts, :scopes, [])
    title = Keyword.get(opts, :title)
    annotations = Keyword.get(opts, :annotations)

    quote do
      @behaviour MCP.Tool
      import MCP.Tool, only: [input: 1, output: 1], warn: false

      Module.register_attribute(__MODULE__, :mcp_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_output_fields, accumulate: true)
      @mcp_field_target nil
      @before_compile MCP.Tool

      @mcp_name MCP.Name.validate!(unquote(name), "MCP.Tool")

      @impl MCP.Tool
      def name, do: @mcp_name

      @impl MCP.Tool
      def scopes, do: unquote(scopes)

      @impl MCP.Tool
      def title, do: unquote(title)

      # Validated at the using module's compile time, so a bad annotation is a
      # compile error there rather than a silently-ignored key on the wire.
      @mcp_annotations MCP.Annotations.tool!(unquote(annotations))

      @impl MCP.Tool
      def annotations, do: @mcp_annotations
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
    opts =
      Keyword.validate!(opts, [
        :required,
        :enum,
        :description,
        :default,
        :items,
        :max_items,
        :min,
        :max
      ])

    validate_array_opts!(name, type, opts)
    validate_bounds!(name, type, opts)
    validate_default!(name, type, opts)
    {name, type, opts}
  end

  def __field__(name, type, _opts) do
    raise ArgumentError,
          "invalid MCP.Tool field #{inspect(name)}: type #{inspect(type)} " <>
            "must be one of #{inspect(@field_types)}"
  end

  @numeric_types [:integer, :number]

  # min:/max: are JSON Schema's minimum/maximum, so they only mean anything on
  # a number. On anything else they would silently never be checked.
  defp validate_bounds!(name, type, opts) do
    for bound <- [:min, :max], value = opts[bound], not is_nil(value) do
      cond do
        type not in @numeric_types ->
          raise ArgumentError,
                "MCP.Tool field #{inspect(name)} declares #{bound}: but is type " <>
                  "#{inspect(type)}; bounds apply to #{inspect(@numeric_types)}"

        not is_number(value) ->
          raise ArgumentError,
                "MCP.Tool field #{inspect(name)} has non-numeric #{bound}: #{inspect(value)}"

        true ->
          :ok
      end
    end

    if is_number(opts[:min]) and is_number(opts[:max]) and opts[:min] > opts[:max] do
      raise ArgumentError,
            "MCP.Tool field #{inspect(name)} has min: greater than max:, which admits nothing"
    end

    :ok
  end

  # items:/max_items: are array-only, and items: is how an array's elements
  # get type-checked, so it can't be left out once type is :array.
  defp validate_array_opts!(name, :array, opts) do
    case opts[:items] do
      items when items in @scalar_types ->
        :ok

      nil ->
        raise ArgumentError,
              "MCP.Tool field #{inspect(name)} is type :array and requires items:"

      items ->
        raise ArgumentError,
              "MCP.Tool field #{inspect(name)} has invalid items: #{inspect(items)}; " <>
                "must be one of #{inspect(@scalar_types)}"
    end

    case opts[:max_items] do
      nil ->
        :ok

      max_items when is_integer(max_items) and max_items > 0 ->
        :ok

      max_items ->
        raise ArgumentError,
              "MCP.Tool field #{inspect(name)} has invalid max_items: #{inspect(max_items)}; " <>
                "must be a positive integer"
    end
  end

  defp validate_array_opts!(name, _type, opts) do
    if Keyword.has_key?(opts, :items) do
      raise ArgumentError,
            "MCP.Tool field #{inspect(name)} declares items: but is not type :array"
    end

    if Keyword.has_key?(opts, :max_items) do
      raise ArgumentError,
            "MCP.Tool field #{inspect(name)} declares max_items: but is not type :array"
    end
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
          {:ok, _coerced} -> :ok
          {:error, message} -> raise ArgumentError, "invalid MCP.Tool default: #{message}"
        end
    end
  end

  @doc false
  def build_schema(fields) do
    properties =
      Map.new(fields, fn {name, type, opts} -> {to_string(name), build_property(type, opts)} end)

    required = for {name, _, opts} <- fields, opts[:required], do: to_string(name)

    %{"type" => "object", "properties" => properties, "additionalProperties" => false}
    |> then(&if required == [], do: &1, else: Map.put(&1, "required", required))
  end

  # A date is a string on the wire; `format` is what says which kind of string.
  defp base_property(:date), do: %{"type" => "string", "format" => "date"}
  defp base_property(type), do: %{"type" => json_type(type)}

  # enum: constrains an array's elements, so it nests inside "items" rather
  # than sitting on the property like it does for scalar fields.
  defp build_property(:array, opts) do
    item_schema =
      opts[:items]
      |> base_property()
      |> maybe_put("enum", opts[:enum])

    %{"type" => json_type(:array), "items" => item_schema}
    |> maybe_put("maxItems", opts[:max_items])
    |> maybe_put("description", opts[:description])
    |> maybe_put("default", opts[:default])
  end

  defp build_property(type, opts) do
    type
    |> base_property()
    |> maybe_put("description", opts[:description])
    |> maybe_put("enum", opts[:enum])
    |> maybe_put("minimum", opts[:min])
    |> maybe_put("maximum", opts[:max])
    |> maybe_put("default", opts[:default])
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
              {:ok, coerced} -> {Map.put(acc, name, coerced), errors}
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

  defp check_value(name, :array, opts, value) do
    cond do
      not is_list(value) ->
        {:error, "#{name} must be an array"}

      is_integer(opts[:max_items]) and length(value) > opts[:max_items] ->
        {:error, "#{name} accepts at most #{opts[:max_items]} items"}

      not Enum.all?(value, &correct_type?(opts[:items], &1)) ->
        {:error, "#{name} items must be #{json_type(opts[:items])}"}

      is_list(opts[:enum]) and not Enum.all?(value, &(&1 in opts[:enum])) ->
        {:error, "#{name} items must each be one of #{inspect(opts[:enum])}"}

      true ->
        {:ok, Enum.map(value, &coerce(opts[:items], &1))}
    end
  end

  # Arrives as a string and reaches call/2 as a Date: the parse belongs with the
  # rest of validation, not repeated in every tool that takes a day.
  defp check_value(name, :date, _opts, value) do
    case cast_date(value) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, "#{name} must be an ISO 8601 date (YYYY-MM-DD)"}
    end
  end

  defp check_value(name, type, opts, value) do
    cond do
      not correct_type?(type, value) ->
        {:error, "#{name} must be a #{json_type(type)}"}

      is_list(opts[:enum]) and value not in opts[:enum] ->
        {:error, "#{name} must be one of #{inspect(opts[:enum])}"}

      is_number(opts[:min]) and value < opts[:min] ->
        {:error, "#{name} must be at least #{opts[:min]}"}

      is_number(opts[:max]) and value > opts[:max] ->
        {:error, "#{name} must be at most #{opts[:max]}"}

      true ->
        {:ok, value}
    end
  end

  defp correct_type?(:string, value), do: is_binary(value)
  defp correct_type?(:integer, value), do: is_integer(value)
  defp correct_type?(:number, value), do: is_number(value)
  defp correct_type?(:boolean, value), do: is_boolean(value)
  defp correct_type?(:array, value), do: is_list(value)
  defp correct_type?(:date, value), do: match?({:ok, _date}, cast_date(value))

  # Already-cast values pass through so a `default:` can be written as ~D[...].
  defp cast_date(%Date{} = date), do: {:ok, date}

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp cast_date(_value), do: :error

  defp coerce(:date, value) do
    {:ok, date} = cast_date(value)
    date
  end

  defp coerce(_type, value), do: value

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:number), do: "number"
  defp json_type(:boolean), do: "boolean"
  defp json_type(:array), do: "array"
  defp json_type(:date), do: "date"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
