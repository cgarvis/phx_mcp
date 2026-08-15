# `locals_without_parens` is exported so consumer apps pick it up via
# `import_deps: [:phx_mcp]`. Without it the formatter rewrites `field :code,
# :string` into `field(:code, :string)` and `mcp "/mcp", opts` into
# `mcp("/mcp", opts)`, contradicting every example in the docs. Inside this
# repo the same list has to be declared, not only exported.
#
# Moxie never hit the `field` half of this: its `import_deps: [:ecto]` happened
# to export `field/2` and `field/3`, so the tool DSL formatted correctly by
# coincidence.
#
# Every public macro a host writes unqualified belongs here.
# `MCP.FormatterExportTest` fails if one is missing, because the failure mode
# is otherwise invisible until a consumer runs `mix format` on their router.
locals_without_parens = [
  # MCP.Router
  mcp: 2,
  mcp_oauth: 2,
  # MCP.Tool, MCP.Prompt
  field: 2,
  field: 3,
  input: 1,
  output: 1,
  arguments: 1,
  # MCP.Elicitation
  form: 2
]

[
  import_deps: [:plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
