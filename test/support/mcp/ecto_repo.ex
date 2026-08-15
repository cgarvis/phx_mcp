if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule MCP.Test.Repo do
    @moduledoc """
    The only Ecto repo phx_mcp's own test suite uses, exercising
    `MCP.OAuth.Store.Ecto` against a real Postgres database.

    Connection config lives in config/config.exs, overridable per DB_*
    environment variable -- CI sets DB_USER/DB_PASSWORD to match its
    Postgres service container. None of it ships with the package: config/
    is not in mix.exs's package :files list.
    """

    use Ecto.Repo, otp_app: :phx_mcp, adapter: Ecto.Adapters.Postgres
  end
end
