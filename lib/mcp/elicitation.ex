defmodule MCP.Elicitation do
  @moduledoc """
  Builders for the `elicitation/create` entries of an `input_required` result.

      import MCP.Elicitation

      request =
        form "Who should I greet?" do
          field :name, :string, required: true
          field :formal, :boolean, default: false
        end

      {:input_required, %{"who_to_greet" => request}, %{}}

  The spec's `InputRequest` is one of three — `elicitation/create`,
  `sampling/createMessage`, or `roots/list`. Only elicitation has builders
  here; the other two are plain maps, and `MCP.Server` already gates all three
  on the matching client capability.

  Fields mirror `MCP.Tool`'s `input` block deliberately: `requestedSchema` is a
  restricted subset of JSON Schema — flat, primitives only, no nesting — which
  is the same shape the tool DSL emits. Options are checked against the
  declared type, since the spec gives each primitive its own key set:

    * all types — `required:`, `title:`, `description:`, `default:`
    * `:string` — `enum:`, `format:` (`:email`, `:uri`, `:date`, `:datetime`),
      `min_length:`, `max_length:`
    * `:integer` and `:number` — `minimum:`, `maximum:`

  Unlike a tool input default, an elicitation `default:` is a form prefill the
  client shows the user, so it combines with `required: true` rather than
  replacing it. Nothing here is enforced server-side — these are annotations
  for the client's form, and a client is free to ignore them.

  Request names are server-assigned identifiers, keyed independently of the
  fields inside them: the client echoes each name back in `inputResponses`, so
  `resume/3` matches the name first and the field second. Give them different
  names — a request called `message` holding a field called `message` reads as
  `%{"message" => %{"message" => value}}`.

  Only accepted responses reach `resume/3`, already unwrapped to their
  `content`; declines and cancellations are answered uniformly by `MCP.Server`,
  so tools write no branch for them.
  """

  @types [:string, :integer, :number, :boolean]
  @formats %{email: "email", uri: "uri", date: "date", datetime: "date-time"}

  @common [:required, :title, :description, :default]
  @by_type %{
    string: @common ++ [:enum, :format, :min_length, :max_length],
    integer: @common ++ [:minimum, :maximum],
    number: @common ++ [:minimum, :maximum],
    boolean: @common
  }

  @doc """
  A form-mode elicitation asking the user for the declared fields.

  `field` inside the block is rewritten at compile time rather than imported,
  so it does not collide with `MCP.Tool`'s own `field` in a tool module.
  """
  defmacro form(message, do: block) do
    fields = block |> unwrap_block() |> Enum.map(&rewrite_field/1)

    quote do
      MCP.Elicitation.__form__(unquote(message), unquote(fields))
    end
  end

  defp unwrap_block({:__block__, _meta, exprs}), do: exprs
  defp unwrap_block(expr), do: [expr]

  defp rewrite_field({:field, _meta, [name, type]}), do: rewrite_field(name, type, [])
  defp rewrite_field({:field, _meta, [name, type, opts]}), do: rewrite_field(name, type, opts)

  defp rewrite_field(other) do
    raise ArgumentError,
          "a form block takes only `field name, type, opts`, got: #{Macro.to_string(other)}"
  end

  defp rewrite_field(name, type, opts) do
    check_literals!(name, type, opts)
    quote do: MCP.Elicitation.__field__(unquote(name), unquote(type), unquote(opts))
  end

  # Types and option keys are literal in practice, so fail at compile time
  # rather than the first time a tool elicits.
  defp check_literals!(name, type, opts) when is_atom(type) and type != nil do
    allowed = Map.get(@by_type, type) || raise ArgumentError, bad_type(name, type)

    if Keyword.keyword?(opts) do
      for key <- Keyword.keys(opts), key not in allowed do
        raise ArgumentError,
              "invalid MCP.Elicitation field #{inspect(name)}: option #{inspect(key)} " <>
                "is not allowed on #{inspect(type)}, expected one of #{inspect(allowed)}"
      end
    end
  end

  defp check_literals!(_name, _type, _opts), do: :ok

  @doc """
  A form-mode elicitation built from a raw `requestedSchema` map.

  The escape hatch for the corners the field DSL does not cover, such as an
  enum carrying per-option display titles via `oneOf`.
  """
  def form_schema(message, requested_schema)
      when is_binary(message) and is_map(requested_schema),
      do: create(%{"mode" => "form", "message" => message, "requestedSchema" => requested_schema})

  @doc "A url-mode elicitation sending the user out of band to complete something."
  def url(message, url) when is_binary(message) and is_binary(url),
    do: create(%{"mode" => "url", "message" => message, "url" => url})

  @doc false
  def __form__(message, fields) when is_binary(message) and is_list(fields) do
    properties = Map.new(fields, fn {name, _required, prop} -> {name, prop} end)
    required = for {name, true, _prop} <- fields, do: name

    schema =
      %{"type" => "object", "properties" => properties}
      |> then(&if required == [], do: &1, else: Map.put(&1, "required", required))

    create(%{"mode" => "form", "message" => message, "requestedSchema" => schema})
  end

  @doc false
  def __field__(name, type, opts) when is_atom(name) and type in @types do
    opts = Keyword.validate!(opts, Map.fetch!(@by_type, type))
    {to_string(name), opts[:required] == true, build(type, opts)}
  end

  def __field__(name, type, _opts), do: raise(ArgumentError, bad_type(name, type))

  defp bad_type(name, type) do
    "invalid MCP.Elicitation field #{inspect(name)}: type #{inspect(type)} " <>
      "must be one of #{inspect(@types)}"
  end

  defp build(type, opts) do
    %{"type" => json_type(type)}
    |> maybe_put("title", opts[:title])
    |> maybe_put("description", opts[:description])
    |> maybe_put("enum", opts[:enum])
    |> maybe_put("format", format(opts[:format]))
    |> maybe_put("minLength", opts[:min_length])
    |> maybe_put("maxLength", opts[:max_length])
    |> maybe_put("minimum", opts[:minimum])
    |> maybe_put("maximum", opts[:maximum])
    |> maybe_put("default", opts[:default])
  end

  defp format(nil), do: nil

  defp format(format) do
    Map.get(@formats, format) ||
      raise ArgumentError,
            "invalid MCP.Elicitation format #{inspect(format)}, " <>
              "expected one of #{inspect(Map.keys(@formats))}"
  end

  defp create(params), do: %{"method" => "elicitation/create", "params" => params}

  defp json_type(:string), do: "string"
  defp json_type(:integer), do: "integer"
  defp json_type(:number), do: "number"
  defp json_type(:boolean), do: "boolean"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
