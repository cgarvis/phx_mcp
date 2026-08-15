if Code.ensure_loaded?(Ecto.Schema) do
  defmodule MCP.OAuth.Store.Ecto.Token do
    @moduledoc """
    Ecto schema behind `mcp_oauth_tokens`, a persistence detail of
    `MCP.OAuth.Store.Ecto`.

    `revoked_at` (a timestamp, not a boolean) is what `MCP.OAuth.Token.revoked?`
    is derived from at the `MCP.OAuth.Store.Ecto` boundary -- `not
    is_nil(revoked_at)`. `MCP.OAuth.Store.Ecto` sets it with an `update_all`
    when revoking rather than through a changeset, since revocation is not a
    field edit on a struct already in hand.

    `sub` is `:string`, not `:binary_id`: nothing in this library assumes a
    resource owner's subject is a UUID, so the column matches
    `MCP.OAuth.Token.t()`'s `sub: String.t() | nil` rather than assuming a
    host's identity scheme. `nil` marks a `client_credentials` token, whose
    principal is the client itself, not a missing value.

    Nulls are fine in both unique indexes the migration creates: Postgres
    does not dedupe NULLs, and `refresh_hash: nil` (a `client_credentials`
    token has no refresh token) is exactly that.
    """

    use Ecto.Schema
    import Ecto.Changeset

    schema "mcp_oauth_tokens" do
      field :access_hash, :string
      field :refresh_hash, :string
      field :client_id, :string
      field :sub, :string
      field :scope, :string
      field :audience, {:array, :string}, default: []
      field :expires_at, :utc_datetime
      field :revoked_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    @type t :: %__MODULE__{}

    @fields [:access_hash, :refresh_hash, :client_id, :sub, :scope, :audience, :expires_at]

    # empty_values: [] -- an unscoped grant's "" is real data, not an
    # omission; cast's default would silently turn it into a NOT NULL
    # violation. No validate_required/2 for the same reason: its default
    # :trim behavior treats "" as blank again, undoing this. revoked_at is
    # deliberately outside @fields: it is only ever written by
    # MCP.OAuth.Store.Ecto.revoke_token/3, never through this changeset.
    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(token, attrs) do
      token
      |> cast(attrs, @fields, empty_values: [])
      |> unique_constraint(:access_hash, name: :mcp_oauth_tokens_access_hash_index)
      |> unique_constraint(:refresh_hash, name: :mcp_oauth_tokens_refresh_hash_index)
    end
  end
end
