# The :ecto tests need a live Postgres and are excluded by default so
# `mix test` stays instant and DB-free; `mix test.ecto` (mix.exs alias) opts
# them back in. See MCP.EctoCase for why the connection itself is never
# dialed unless a test that needs it actually runs.
ExUnit.start(exclude: [:ecto])
