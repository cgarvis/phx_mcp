if Code.ensure_loaded?(Ecto.Schema) do
  defmodule MCP.OAuth.Store.Ecto.Code do
    @moduledoc """
    Ecto schema behind `mcp_oauth_codes`, a persistence detail of
    `MCP.OAuth.Store.Ecto`.

    No `timestamps/0`: a row is meant to live for one `MCP.OAuth.Store.Ecto`
    call each way -- `put_code/1` inserts it, `take_code/1` deletes it -- so
    there is nothing here worth dating. The unique index on `code_hash` is
    what backs `Ecto.Changeset.unique_constraint/3` in `changeset/2`, not a
    correctness requirement of `take_code/1` itself; the `DELETE ... RETURNING`
    that `MCP.OAuth.Store.Ecto` issues there is atomic with or without it.
    """

    use Ecto.Schema
    import Ecto.Changeset

    schema "mcp_oauth_codes" do
      field :code_hash, :string
      field :client_id, :string
      field :redirect_uri, :string
      field :challenge, :string
      field :challenge_method, :string
      field :scope, :string
      field :sub, :string
      field :resource, :string
      field :expires_at, :utc_datetime
    end

    @type t :: %__MODULE__{}

    @fields [
      :code_hash,
      :client_id,
      :redirect_uri,
      :challenge,
      :challenge_method,
      :scope,
      :sub,
      :resource,
      :expires_at
    ]

    # empty_values: [] -- an unscoped grant's "" is real data, not an
    # omission; cast's default would silently turn it into a NOT NULL
    # violation. No validate_required/2 for the same reason: its default
    # :trim behavior treats "" as blank again, undoing this.
    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(code, attrs) do
      code
      |> cast(attrs, @fields, empty_values: [])
      |> unique_constraint(:code_hash, name: :mcp_oauth_codes_code_hash_index)
    end
  end
end
