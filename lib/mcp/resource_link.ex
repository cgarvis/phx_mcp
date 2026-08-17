defmodule MCP.ResourceLink do
  @moduledoc """
  Validation for the `resource_link` content blocks a tool result carries
  alongside its structured output.

  A tool returns links as plain maps from `call/2`'s three-element success
  tuple, and `MCP.Server` builds the wire blocks from them:

      {:ok, %{count: 2},
       [
         %{uri: "myapp://orders/41", name: "order-41", mime_type: "application/json"},
         %{uri: "myapp://orders/42", name: "order-42", mime_type: "application/json"}
       ]}

  Keys are snake_case atoms; the spec's camelCase `mimeType` is produced here
  and nowhere else, the same split `MCP.Annotations` keeps for its own wire
  names. A keyword list is accepted wherever a map is.

    * `:uri` — required, a non-empty string; the URI a client hands to
      `resources/read`
    * `:name` — required, a non-empty string; the resource's programmatic name
    * `:title` — optional display name, for clients that show one
    * `:description` — optional
    * `:mime_type` — optional, emitted as `mimeType`
    * `:annotations` — optional, a keyword list validated by
      `MCP.Annotations.content!/1` (`audience:`, `priority:`, `last_modified:`)

  A key present with `nil` is treated as absent, so a tool can compute an
  optional value without branching around it.

  The key set is closed and both required keys are checked for the same reason
  `MCP.Annotations` validates its input: a client ignores a block key it does
  not recognise, so a typo'd `:mimetype`, or a link with no `:uri` at all,
  would otherwise serialize, ship, and be dropped on the client with nothing
  failing anywhere. Bad links raise `ArgumentError` at the boundary instead.

  The spec's optional `size` is deliberately not accepted: it is the byte
  length of the resource's content, which a tool handing out a pointer has
  usually not read. A tool that wants to publish one can put it in
  `structuredContent`, where it is data rather than a protocol field.

  Nothing here checks that a URI resolves — only the server knows what it
  serves. Point links at this server's own `MCP.Resource` URIs, or at
  expansions of an `MCP.ResourceTemplate`.
  """

  @typedoc "A resource link as a tool returns it."
  @type link :: map() | keyword()

  @typedoc "The `resource_link` content block `new!/1` produces."
  @type block :: map()

  @keys [:uri, :name, :title, :description, :mime_type, :annotations]
  @required [:uri, :name]

  @doc """
  Builds one `resource_link` content block, or raises.

  Raises `ArgumentError` on an unknown key, a missing or non-string `:uri` or
  `:name`, or a non-string optional value. Annotations go through
  `MCP.Annotations.content!/1`, which raises the same way.
  """
  @spec new!(link()) :: block()
  def new!(link) when is_list(link) do
    if Keyword.keyword?(link) do
      link |> Map.new() |> new!()
    else
      raise_not_link!(link)
    end
  end

  def new!(link) when is_map(link) and not is_struct(link) do
    validate_keys!(link)

    %{
      "type" => "resource_link",
      "uri" => required!(link, :uri),
      "name" => required!(link, :name)
    }
    |> maybe_put("title", optional!(link, :title))
    |> maybe_put("description", optional!(link, :description))
    |> maybe_put("mimeType", optional!(link, :mime_type))
    |> maybe_put("annotations", MCP.Annotations.content!(Map.get(link, :annotations)))
  end

  def new!(other), do: raise_not_link!(other)

  ## Private

  defp validate_keys!(link) do
    Enum.each(Map.keys(link), fn key ->
      unless key in @keys do
        raise ArgumentError,
              "unknown MCP resource link key #{inspect(key)}, expected one of #{inspect(@keys)}"
      end
    end)
  end

  # A link with no URI is a link to nothing, and so is one with "": the client
  # has nothing to call resources/read with either way.
  defp required!(link, key) when key in @required do
    case Map.get(link, key) do
      value when is_binary(value) and value != "" ->
        value

      nil ->
        raise ArgumentError,
              "MCP resource link #{inspect(link)} is missing required #{inspect(key)}"

      other ->
        raise ArgumentError,
              "invalid MCP resource link #{inspect(key)} #{inspect(other)}: " <>
                "expected a non-empty string"
    end
  end

  defp optional!(link, key) do
    case Map.get(link, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value

      other ->
        raise ArgumentError,
              "invalid MCP resource link #{inspect(key)} #{inspect(other)}: expected a string"
    end
  end

  defp raise_not_link!(other) do
    raise ArgumentError,
          "invalid MCP resource link #{inspect(other)}: expected a map or keyword list " <>
            "with keys from #{inspect(@keys)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
