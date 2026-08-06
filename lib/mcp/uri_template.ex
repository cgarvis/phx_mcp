defmodule MCP.URITemplate do
  @moduledoc """
  Level-1 RFC 6570 URI templates: `{var}` expressions with simple-string
  expansion. `match/2` inverts expansion — each variable claims one or more
  characters, never a `/`, greedily with backtracking; captured values are
  percent-decoded.

  The decoded value is held to the same invariant as the raw one: a candidate
  that decodes to something containing `/`, or to invalid UTF-8, is rejected
  rather than returned. Otherwise `%2F` would put a separator back into a value
  the matcher had already classified as a single segment.

  Compiled templates are plain data (no regex), so they can live in module
  attributes.
  """

  defstruct [:source, :segments, :vars]

  @type t :: %__MODULE__{
          source: String.t(),
          segments: [{:lit, String.t()} | {:var, String.t()}],
          vars: [String.t()]
        }

  @var_name ~r/^[A-Za-z0-9_]+$/

  @doc "Compiles a template, raising `ArgumentError` on malformed or variable-free input."
  def compile!(source) when is_binary(source) do
    {segments, vars} = parse(source, source, [], [])

    if vars == [] do
      raise ArgumentError,
            "URI template #{inspect(source)} has no variables; use a plain MCP.Resource"
    end

    %__MODULE__{source: source, segments: segments, vars: vars}
  end

  @doc "Matches a concrete URI, returning `{:ok, params}` (string-keyed) or `:nomatch`."
  def match(%__MODULE__{segments: segments}, uri) when is_binary(uri) do
    do_match(segments, uri, %{})
  end

  defp parse(rest, source, segments, vars) do
    case String.split(rest, "{", parts: 2) do
      [literal] ->
        ensure_no_stray_brace!(literal, source)
        {Enum.reverse(add_literal(segments, literal)), Enum.reverse(vars)}

      [literal, after_brace] ->
        ensure_no_stray_brace!(literal, source)
        {var, rest} = take_var!(after_brace, source)

        if var in vars do
          raise ArgumentError,
                "duplicate variable #{inspect(var)} in URI template #{inspect(source)}"
        end

        parse(rest, source, [{:var, var} | add_literal(segments, literal)], [var | vars])
    end
  end

  defp add_literal(segments, ""), do: segments
  defp add_literal(segments, literal), do: [{:lit, literal} | segments]

  defp take_var!(after_brace, source) do
    case String.split(after_brace, "}", parts: 2) do
      [var, rest] ->
        if var =~ @var_name do
          {var, rest}
        else
          raise ArgumentError,
                "invalid variable #{inspect(var)} in URI template #{inspect(source)}"
        end

      [_unclosed] ->
        raise ArgumentError, "unclosed variable in URI template #{inspect(source)}"
    end
  end

  defp ensure_no_stray_brace!(literal, source) do
    if String.contains?(literal, "}") do
      raise ArgumentError, "stray } in URI template #{inspect(source)}"
    end
  end

  defp do_match([], "", params), do: {:ok, params}
  defp do_match([], _rest, _params), do: :nomatch

  defp do_match([{:lit, lit} | segments], uri, params) do
    size = byte_size(lit)

    if String.starts_with?(uri, lit) do
      do_match(segments, binary_part(uri, size, byte_size(uri) - size), params)
    else
      :nomatch
    end
  end

  defp do_match([{:var, name} | segments], uri, params) do
    try_var(span_before_slash(uri), name, segments, uri, params)
  end

  # Longest candidate first, shrinking until the remaining segments match.
  defp try_var(0, _name, _segments, _uri, _params), do: :nomatch

  defp try_var(len, name, segments, uri, params) do
    value = binary_part(uri, 0, len)
    tail = binary_part(uri, len, byte_size(uri) - len)

    with {:ok, matched} <- do_match(segments, tail, params),
         {:ok, decoded} <- decode(value) do
      {:ok, Map.put(matched, name, decoded)}
    else
      _nomatch -> try_var(len - 1, name, segments, uri, params)
    end
  end

  # Decoding happens after the slash boundary is fixed, so re-check it here.
  defp decode(value) do
    decoded = URI.decode(value)

    if String.contains?(decoded, "/") or not String.valid?(decoded),
      do: :nomatch,
      else: {:ok, decoded}
  end

  defp span_before_slash(uri) do
    case :binary.match(uri, "/") do
      {pos, _len} -> pos
      :nomatch -> byte_size(uri)
    end
  end
end
