defmodule MCP.Test.Repo.Migrations.CreateMcpOauthTables do
  use Ecto.Migration

  # mcp_oauth_clients, mcp_oauth_codes, mcp_oauth_tokens: fixed table
  # names owned by MCP.OAuth.Store.Ecto, the way oban_jobs is owned by
  # Oban. See that module's moduledoc for the column-by-column
  # reasoning -- in particular, sub is :string (not :binary_id) and
  # every hash column is :string (not :binary).
  def change do
    create table(:mcp_oauth_clients, primary_key: false) do
      add :id, :string, primary_key: true
      add :secret_hash, :string
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :scopes, {:array, :string}, null: false, default: []
      add :grant_types, {:array, :string}, null: false, default: []
      add :confidential, :boolean, null: false, default: false
      add :pkce_required, :boolean, null: false, default: true
      add :name, :string
      add :client_uri, :string
      add :logo_uri, :string
      add :dynamically_registered, :boolean, null: false, default: false
      add :cimd, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    # Single-use, hashed at rest. MCP.OAuth.Store.Ecto.take_code/3
    # deletes on read via one atomic DELETE ... RETURNING, so a row
    # never outlives its use -- no separate expiry sweep needed for
    # replay safety, only for cleanup of abandoned (never-redeemed)
    # codes.
    create table(:mcp_oauth_codes) do
      add :code_hash, :string, null: false
      add :client_id, :string, null: false
      add :redirect_uri, :string, null: false
      add :challenge, :string
      add :challenge_method, :string
      add :scope, :string, null: false
      add :sub, :string
      add :resource, :string
      add :expires_at, :utc_datetime, null: false
    end

    create unique_index(:mcp_oauth_codes, [:code_hash])

    # revoked_at (not a boolean) is what MCP.OAuth.Token.revoked?/1 is
    # derived from. Nulls are fine in both unique indexes below:
    # Postgres does not dedupe NULLs, and client_credentials tokens
    # (no refresh_hash) and every not-yet-revoked row are exactly that.
    create table(:mcp_oauth_tokens) do
      add :access_hash, :string, null: false
      add :refresh_hash, :string
      add :client_id, :string, null: false
      add :sub, :string
      add :scope, :string, null: false
      add :audience, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mcp_oauth_tokens, [:access_hash])
    create unique_index(:mcp_oauth_tokens, [:refresh_hash])
  end
end
