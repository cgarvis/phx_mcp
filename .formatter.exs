# `locals_without_parens` is exported so consumer apps pick it up via
# `import_deps: [:mcp]`. Without it the formatter rewrites `field :code, :string`
# into `field(:code, :string)` inside every input/output/arguments/form block.
# Inside this repo the same list has to be declared, not only exported.
#
# Moxie never hit this: its `import_deps: [:ecto]` happened to export `field/2`
# and `field/3`, so this library's DSL formatted correctly by coincidence.
locals_without_parens = [
  field: 2,
  field: 3,
  form: 2,
  input: 1,
  output: 1,
  arguments: 1
]

[
  import_deps: [:plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
