defmodule MCP.FormatterExportTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards `.formatter.exs`'s exported `locals_without_parens`.

  A missing entry has no local symptom: this library's own suite passes, and
  the damage only shows up when a consumer with `import_deps: [:phx_mcp]` runs
  `mix format` and their router or tool is rewritten into a form no example in
  the docs uses. That happened once already, when `MCP.Router` landed after the
  list was written, so it is now a test rather than a thing to remember.
  """

  # Every module whose macros a host writes unqualified, having imported or
  # used it. A macro reachable only as `MCP.Thing.macro(...)` does not need an
  # entry, since the formatter leaves qualified calls alone.
  @dsl_modules [MCP.Router, MCP.Tool, MCP.Prompt, MCP.Elicitation]

  # __using__, __before_compile__, and friends are invoked by the compiler, never
  # written in a host's source, so the formatter never sees them as local calls.
  defp compiler_hook?(name) do
    name = Atom.to_string(name)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  defp exported_locals do
    {config, _bindings} = Code.eval_file(".formatter.exs")
    config |> Keyword.fetch!(:export) |> Keyword.fetch!(:locals_without_parens)
  end

  test "every public DSL macro is in the exported locals_without_parens" do
    exported = exported_locals()

    # `\\ default` expands to one entry per arity, and the formatter matches on
    # arity, so each has to be listed separately.
    missing =
      for module <- @dsl_modules,
          {name, arity} <- module.__info__(:macros),
          not compiler_hook?(name),
          {name, arity} not in exported,
          do: {module, name, arity}

    assert missing == [],
           """
           Public DSL macros missing from .formatter.exs locals_without_parens:

           #{Enum.map_join(missing, "\n", fn {m, n, a} -> "    #{inspect(m)}: #{n}/#{a}" end)}

           A consumer running `mix format` would have these rewritten into
           parenthesized calls, contradicting the documented examples.
           """
  end

  test "the declared and exported lists are the same" do
    {config, _bindings} = Code.eval_file(".formatter.exs")

    assert Keyword.fetch!(config, :locals_without_parens) == exported_locals(),
           "this repo formats its own code differently than it tells consumers to"
  end
end
