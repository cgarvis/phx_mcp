if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule MCP.Test.OAuthStore do
    @moduledoc "An `MCP.OAuth.Store.Ecto` instance over `MCP.Test.Repo`, no prefix."
    use MCP.OAuth.Store.Ecto, repo: MCP.Test.Repo
  end
end
