defmodule MCP.OAuth.TestFixtures do
  @moduledoc "Client struct builders for MCP.OAuth tests — not a Store, just plain data."

  alias MCP.OAuth.{Client, Secret}

  @doc "A confidential client with a known plaintext secret. Returns `{client, plaintext_secret}`."
  def confidential_client(attrs \\ %{}) do
    secret = Map.get(attrs, :secret, "s3cr3t-" <> Secret.new())

    client = %Client{
      id: Map.get(attrs, :id, "client-" <> Secret.new()),
      secret_hash: Secret.hash(secret),
      redirect_uris: Map.get(attrs, :redirect_uris, ["https://client.test/callback"]),
      scopes: Map.get(attrs, :scopes, ["mcp:read", "mcp:write"]),
      grant_types:
        Map.get(attrs, :grant_types, ["authorization_code", "refresh_token", "client_credentials"]),
      confidential?: true,
      pkce_required?: Map.get(attrs, :pkce_required?, false)
    }

    {client, secret}
  end

  @doc "A public client — no secret, PKCE mandatory."
  def public_client(attrs \\ %{}) do
    %Client{
      id: Map.get(attrs, :id, "client-" <> Secret.new()),
      secret_hash: nil,
      redirect_uris: Map.get(attrs, :redirect_uris, ["https://client.test/callback"]),
      scopes: Map.get(attrs, :scopes, ["mcp:read", "mcp:write"]),
      grant_types: Map.get(attrs, :grant_types, ["authorization_code", "refresh_token"]),
      confidential?: false,
      pkce_required?: true
    }
  end
end
