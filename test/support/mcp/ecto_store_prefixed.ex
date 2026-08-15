if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule MCP.Test.OAuthStorePrefixed do
    @moduledoc "The same store, exercising the :prefix option (the default Postgres schema)."
    use MCP.OAuth.Store.Ecto, repo: MCP.Test.Repo, prefix: "public"
  end
end
