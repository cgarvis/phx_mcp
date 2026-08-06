defmodule MCP.OAuth.Token do
  @moduledoc """
  An issued access token, hashed at rest, paired with its refresh token if any.

  `audience` is the RFC 8707 resource list `MCP.OAuth.verify_token/3` checks
  a caller's target against. `sub: nil` marks a client_credentials token,
  whose principal is the client itself.
  """

  @enforce_keys [:access_hash, :client_id, :scope, :audience, :expires_at]
  defstruct [
    :access_hash,
    :refresh_hash,
    :client_id,
    :sub,
    :scope,
    :audience,
    :expires_at,
    revoked?: false
  ]

  @type t :: %__MODULE__{
          access_hash: String.t(),
          refresh_hash: String.t() | nil,
          client_id: String.t(),
          sub: String.t() | nil,
          scope: String.t(),
          audience: [String.t()],
          expires_at: DateTime.t(),
          revoked?: boolean()
        }
end
