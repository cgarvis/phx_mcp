defmodule MCP.Annotations do
  @moduledoc """
  Compile-time validation for the spec's two annotation shapes.

  Both are closed sets with fixed value types, and both are declared
  statically in a `use` block, so every mistake in one is catchable before
  the module finishes compiling. That is the whole reason these are not a
  pass-through `map()`: an annotation is advisory, so a client that does not
  recognise a key ignores it, and a typo like `readonlyHint` or `audiance`
  would otherwise serialize, ship, and never fail anywhere.

  Declarations are snake_case keyword lists; the spec's camelCase wire names
  are produced here and nowhere else.

  `MCP.Resource` / `MCP.ResourceTemplate` take `resource!/1`:

      annotations: [audience: [:assistant], priority: 0.8]
      #=> %{"audience" => ["assistant"], "priority" => 0.8}

    * `:audience` — who the content is for, a non-empty list of `:user`
      and/or `:assistant`
    * `:priority` — importance, a number from 0 to 1 inclusive
    * `:last_modified` — an ISO 8601 timestamp

  `MCP.Tool` takes `tool!/1`, whose keys are all booleans:

      annotations: [read_only: true, open_world: false]
      #=> %{"readOnlyHint" => true, "openWorldHint" => false}

    * `:read_only` — the tool does not modify state
    * `:destructive` — it may perform destructive updates
    * `:idempotent` — repeat calls with the same arguments have no added effect
    * `:open_world` — it touches an open world (the internet), not a closed one

  `ToolAnnotations.title` is deliberately not accepted: `title:` is its own
  `use` option and is emitted at the top level of the tool payload, which is
  where this revision wants it. Two ways to set one title is one too many.
  """

  @resource_keys [:audience, :priority, :last_modified]
  @tool_keys [:read_only, :destructive, :idempotent, :open_world]
  @roles [:user, :assistant]

  @tool_wire_names %{
    read_only: "readOnlyHint",
    destructive: "destructiveHint",
    idempotent: "idempotentHint",
    open_world: "openWorldHint"
  }

  @doc "Validates resource/content annotations, returning the wire map or nil."
  @spec resource!(keyword() | nil) :: map() | nil
  def resource!(nil), do: nil

  # An empty annotations object says nothing, so it is absent, not emitted.
  def resource!([]), do: nil

  def resource!(opts) when is_list(opts) do
    opts
    |> validate_keyword!(@resource_keys, "resource")
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, resource_wire_name(key), resource_value!(key, value))
    end)
  end

  def resource!(other), do: raise_not_keyword!(other, @resource_keys)

  @doc """
  Validates content-block annotations, returning the wire map or nil.

  The spec has one `Annotations` type, carried by `Resource` and by every
  content block (`TextContent`, `ImageContent`, `EmbeddedResource`, and
  `ResourceLink` through the `Resource` it extends). This is `resource!/1`
  under the name that reads right at a content call site.
  """
  @spec content!(keyword() | nil) :: map() | nil
  def content!(opts), do: resource!(opts)

  @doc "Validates tool annotations, returning the wire map or nil."
  @spec tool!(keyword() | nil) :: map() | nil
  def tool!(nil), do: nil

  def tool!([]), do: nil

  def tool!(opts) when is_list(opts) do
    opts
    |> validate_keyword!(@tool_keys, "tool")
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      unless is_boolean(value) do
        raise ArgumentError,
              "invalid MCP tool annotation #{inspect(key)}: expected a boolean, got #{inspect(value)}"
      end

      Map.put(acc, Map.fetch!(@tool_wire_names, key), value)
    end)
  end

  def tool!(other), do: raise_not_keyword!(other, @tool_keys)

  ## Private

  defp validate_keyword!(opts, allowed, kind) do
    unless Keyword.keyword?(opts) do
      raise_not_keyword!(opts, allowed)
    end

    Enum.each(Keyword.keys(opts), fn key ->
      unless key in allowed do
        raise ArgumentError,
              "unknown MCP #{kind} annotation #{inspect(key)}, expected one of #{inspect(allowed)}"
      end
    end)

    case Keyword.keys(opts) -- Enum.uniq(Keyword.keys(opts)) do
      [] -> opts
      dups -> raise ArgumentError, "duplicate MCP #{kind} annotations: #{inspect(dups)}"
    end
  end

  defp raise_not_keyword!(other, allowed) do
    raise ArgumentError,
          "invalid MCP annotations #{inspect(other)}: expected a keyword list " <>
            "with keys from #{inspect(allowed)}"
  end

  defp resource_wire_name(:last_modified), do: "lastModified"
  defp resource_wire_name(key), do: to_string(key)

  defp resource_value!(:audience, roles) when is_list(roles) and roles != [] do
    Enum.each(roles, fn role ->
      unless role in @roles do
        raise ArgumentError,
              "invalid MCP audience #{inspect(role)}, expected one of #{inspect(@roles)}"
      end
    end)

    case roles -- Enum.uniq(roles) do
      [] -> Enum.map(roles, &to_string/1)
      dups -> raise ArgumentError, "duplicate MCP audience roles: #{inspect(dups)}"
    end
  end

  defp resource_value!(:audience, other) do
    raise ArgumentError,
          "invalid MCP audience #{inspect(other)}: expected a non-empty list of #{inspect(@roles)}"
  end

  defp resource_value!(:priority, value) when is_number(value) and value >= 0 and value <= 1,
    do: value

  defp resource_value!(:priority, other) do
    raise ArgumentError,
          "invalid MCP priority #{inspect(other)}: expected a number from 0 to 1 inclusive"
  end

  defp resource_value!(:last_modified, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "invalid MCP last_modified #{inspect(value)}: not an ISO 8601 timestamp (#{inspect(reason)})"
    end
  end

  defp resource_value!(:last_modified, other) do
    raise ArgumentError,
          "invalid MCP last_modified #{inspect(other)}: expected an ISO 8601 string"
  end
end
