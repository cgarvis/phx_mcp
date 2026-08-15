import Config

# MCP.Test.Repo exists only to exercise MCP.OAuth.Store.Ecto in this
# library's own :ecto test suite (mix test.ecto / mix test --include ecto);
# see test/support/mcp/ecto_case.ex. This file never ships: config/ is not in
# mix.exs's package :files list, so a host project never sees or inherits it.
config :phx_mcp, ecto_repos: [MCP.Test.Repo]

config :phx_mcp, MCP.Test.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "phx_mcp_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
