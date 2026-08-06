defmodule MCP.Prompt do
  @moduledoc """
  Behaviour + DSL for MCP prompts: named, user-invocable message templates
  served via `prompts/list` and `prompts/get`.

      defmodule MyApp.MCP.Prompts.CodeReview do
        use MCP.Prompt, name: "code-review", scopes: []

        @impl true
        def description, do: "Ask for a code review"

        arguments do
          field :code, :string, required: true, description: "The code to review"
        end

        @impl true
        def get(%__MODULE__{code: code}, %MCP.Context{}) do
          {:ok, [{:user, "Please review this code:\\n" <> code}]}
        end
      end

  Fields read the same as `MCP.Tool`'s, except the type must be `:string`: the
  spec's `PromptArgument` is `{name, title, description, required}` with no
  type slot, so every prompt argument arrives as a string. The type stays in
  the signature anyway, so one `field name, type, opts` shape covers tools,
  prompts, and `MCP.Elicitation`. Validation runs before `get/2`: a missing
  required, non-string, or undeclared argument is a -32602.

  The declarations also define a struct on the prompt module, and that struct
  is what `get/2` receives. Matching `%__MODULE__{}` makes a misspelled
  argument a compile error rather than a clause that silently never matches.
  Required arguments are in `@enforce_keys`; an omitted argument arrives as its
  `default:`, or `nil` if it declares none.

  A `default:` is what makes an argument optional, so it cannot be combined
  with `required: true`. Unlike a tool's, it is not advertised: the spec's
  `PromptArgument` is `{name, title, description, required}` with no slot for a
  default, so the value applies server-side only. Say so in `description:` if
  the caller needs to know.

  `get/2` returns `{:ok, messages}` or `{:error, message}` (a -32603). Each
  message is `{:user, text}`, `{:assistant, text}`, or a raw spec-shaped map
  for non-text content (images, resource links, embedded resources), passed
  through as-is.

  A caller whose scopes don't cover `scopes/0` cannot list or get the prompt;
  the error is identical to a nonexistent name.
  """

  @type message :: {:user, String.t()} | {:assistant, String.t()} | map()

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback scopes() :: [String.t()]
  @callback get(args :: struct(), ctx :: MCP.Context.t()) ::
              {:ok, [message]} | {:error, String.t()}

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    scopes = Keyword.get(opts, :scopes, [])

    quote do
      @behaviour MCP.Prompt
      import MCP.Prompt, only: [arguments: 1], warn: false

      Module.register_attribute(__MODULE__, :mcp_arguments, accumulate: true)
      @before_compile MCP.Prompt

      @impl MCP.Prompt
      def name, do: unquote(name)

      @impl MCP.Prompt
      def scopes, do: unquote(scopes)
    end
  end

  defmacro arguments(do: block) do
    quote do
      # Re-importing MCP.Prompt supersedes the :only from `use`, so restate it all.
      import MCP.Prompt, only: [arguments: 1, field: 2, field: 3], warn: false
      unquote(block)
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @mcp_arguments MCP.Prompt.__argument__(unquote(name), unquote(type), unquote(opts))
    end
  end

  defmacro __before_compile__(env) do
    args = env.module |> Module.get_attribute(:mcp_arguments) |> Enum.reverse()
    required = for {name, opts} <- args, opts[:required], do: name
    keys = struct_keys(args)

    quote do
      def __mcp_arguments__, do: unquote(Macro.escape(args))

      # Injected last so handlers above can already match %__MODULE__{}.
      @enforce_keys unquote(required)
      defstruct unquote(Macro.escape(keys))
    end
  end

  # defstruct wants bare atoms before {key, default} pairs.
  defp struct_keys(args) do
    {defaulted, plain} =
      Enum.split_with(args, fn {_name, opts} -> Keyword.has_key?(opts, :default) end)

    Enum.map(plain, fn {name, _opts} -> name end) ++
      Enum.map(defaulted, fn {name, opts} -> {name, opts[:default]} end)
  end

  @doc false
  def __argument__(name, :string, opts) when is_atom(name) do
    opts = Keyword.validate!(opts, [:required, :description, :default])
    validate_default!(name, opts)
    {name, opts}
  end

  # PromptArgument has no type slot on the wire, so :string is the only honest one.
  def __argument__(name, type, _opts) do
    raise ArgumentError,
          "invalid MCP.Prompt field #{inspect(name)}: type #{inspect(type)} must be :string, " <>
            "since prompt arguments are always strings"
  end

  # A default is what makes an argument optional, so the two are exclusive.
  defp validate_default!(name, opts) do
    cond do
      not Keyword.has_key?(opts, :default) ->
        :ok

      opts[:required] ->
        raise ArgumentError,
              "MCP.Prompt argument #{inspect(name)} is both required and defaulted; " <>
                "a default makes the argument optional"

      not is_binary(opts[:default]) ->
        raise ArgumentError,
              "invalid MCP.Prompt default for #{inspect(name)}: prompt arguments are strings"

      true ->
        :ok
    end
  end

  @doc """
  Validates string-keyed `args` against `module`'s declared arguments.

  Checks required and string-ness; rejects undeclared keys. Returns the
  prompt's own struct, handed to `get/2` (keys come from the compile-time
  argument list, never from input). Omitted optional arguments are `nil`.
  """
  def validate_args(module, args) when is_atom(module) and is_map(args) do
    case validate_arguments(module.__mcp_arguments__(), args) do
      {:ok, validated} -> {:ok, struct!(module, validated)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_arguments(arguments, args) do
    known = for {name, _opts} <- arguments, do: to_string(name)

    unknown_errors =
      for key <- Map.keys(args), key not in known, do: "unknown argument: #{inspect(key)}"

    {validated, arg_errors} =
      Enum.reduce(arguments, {%{}, []}, fn {name, opts}, {acc, errors} ->
        case Map.fetch(args, to_string(name)) do
          {:ok, value} when is_binary(value) ->
            {Map.put(acc, name, value), errors}

          {:ok, _value} ->
            {acc, ["#{name} must be a string" | errors]}

          :error ->
            if opts[:required] do
              {acc, ["#{name} is required" | errors]}
            else
              {acc, errors}
            end
        end
      end)

    case unknown_errors ++ Enum.reverse(arg_errors) do
      [] -> {:ok, validated}
      errors -> {:error, errors}
    end
  end
end
