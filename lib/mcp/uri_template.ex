defmodule MCP.URITemplate do
  @moduledoc """
  RFC 6570 URI templates: `{var}` (Level 1, simple-string expansion) and
  `{+var}` (Level 2, reserved expansion). `match/2` inverts expansion — each
  variable claims one or more characters greedily with backtracking, and
  captured values are percent-decoded.

  A plain `{var}` never crosses a `/`: that keeps backtracking bounded by
  segment count rather than combinatorial over the whole URI, and a value
  that decodes to something containing `/` (or to invalid UTF-8) is rejected
  rather than returned. Otherwise `%2F` would put a separator back into a
  value the matcher had already classified as a single segment.

  A `{+var}` may claim `/`, for the deliberate "rest of the path" case --
  `croft://{org}/{ws}/files/{+path}` matching a stored file at
  `reports/2026-08-25.md`, where `path` is `"reports/2026-08-25.md"` whole.
  It is legal only as the template's final expression: no literal and no
  other variable may follow it. Two reserved variables in one template would
  make matching combinatorial over attacker-supplied URIs -- a DoS surface on
  a public endpoint -- and an ambiguous template like `{+a}/{+b}` would only
  ever resolve by an arbitrary "first greedy match wins", so `compile!/1`
  refuses both outright instead of picking a split silently. A `{+var}`'s
  name excludes the leading `+`: `{+path}` produces the variable `"path"`,
  exactly as `{path}` would.

  Percent-escapes inside a reserved variable still decode normally, so
  `%2F` decodes to `/` and `a%2Fb` matches identically to a literal `a/b`.
  That collision is inherent to reserved expansion -- RFC 6570 leaves `/`
  unencoded precisely so it can appear literally, and a consumer that joins
  path segments back together cannot tell the two forms apart either.
  Invalid UTF-8 is still rejected.

  Compiled templates are plain data (no regex), so they can live in module
  attributes.
  """

  defstruct [:source, :segments, :vars]

  @type t :: %__MODULE__{
          source: String.t(),
          segments: [{:lit, String.t()} | {:var, String.t()} | {:reserved, String.t()}],
          vars: [String.t()]
        }

  @var_name ~r/^[A-Za-z0-9_]+$/

  @doc """
  Compiles a template, raising `ArgumentError` on malformed or variable-free
  input, or on a `{+var}` that is not the template's final expression.
  """
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
        {reserved?, var, rest} = take_var!(after_brace, source)

        if var in vars do
          raise ArgumentError,
                "duplicate variable #{inspect(var)} in URI template #{inspect(source)}"
        end

        # Bounded backtracking (and an unambiguous split) both depend on a
        # reserved variable being the last thing left to match, so anything
        # after it -- literal or variable -- is refused here rather than left
        # to resolve by whichever greedy match happens to run first.
        if reserved? and rest != "" do
          raise ArgumentError,
                "{+#{var}} in URI template #{inspect(source)} must be the template's final " <>
                  "expression; a reserved variable may claim `/`, so anything after it makes " <>
                  "the split ambiguous and backtracking combinatorial"
        end

        segment = if reserved?, do: {:reserved, var}, else: {:var, var}
        parse(rest, source, [segment | add_literal(segments, literal)], [var | vars])
    end
  end

  defp add_literal(segments, ""), do: segments
  defp add_literal(segments, literal), do: [{:lit, literal} | segments]

  defp take_var!(after_brace, source) do
    case String.split(after_brace, "}", parts: 2) do
      [raw, rest] ->
        {reserved?, var} = split_operator(raw)

        if var =~ @var_name do
          {reserved?, var, rest}
        else
          raise ArgumentError,
                "invalid variable #{inspect(raw)} in URI template #{inspect(source)}"
        end

      [_unclosed] ->
        raise ArgumentError, "unclosed variable in URI template #{inspect(source)}"
    end
  end

  # The `+` operator marks Level-2 reserved expansion; it is not part of the
  # name, so it is stripped before `@var_name` ever sees it. `{+}` and
  # `{++x}` both still fail that check -- an empty name and a name that still
  # contains `+` respectively -- so no separate validation is needed for them.
  defp split_operator("+" <> var), do: {true, var}
  defp split_operator(var), do: {false, var}

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

  # Compile-time guarantees this is always the last segment, so it claims
  # everything left in one shot instead of the level-1 backtracking search --
  # there is nothing after it to backtrack for.
  defp do_match([{:reserved, name} | segments], uri, params) do
    if uri == "" do
      :nomatch
    else
      with {:ok, decoded} <- decode_reserved(uri) do
        do_match(segments, "", Map.put(params, name, decoded))
      end
    end
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

  # Same decode as Level-1's, minus the slash rejection: a reserved variable
  # is allowed to contain `/` in the first place, so there is nothing for
  # `%2F` to smuggle past that isn't already allowed unescaped.
  defp decode_reserved(value) do
    decoded = URI.decode(value)
    if String.valid?(decoded), do: {:ok, decoded}, else: :nomatch
  end

  defp span_before_slash(uri) do
    case :binary.match(uri, "/") do
      {pos, _len} -> pos
      :nomatch -> byte_size(uri)
    end
  end
end
