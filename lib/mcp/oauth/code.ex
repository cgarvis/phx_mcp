defmodule MCP.OAuth.Code do
  @moduledoc """
  A single-use authorization code, hashed at rest.

  `challenge`/`challenge_method` carry the PKCE parameters from
  `MCP.OAuth.authorize/3` forward to `MCP.OAuth.token/2`, the only place they
  are checked. `resource` is the RFC 8707 target that becomes the minted
  token's sole audience entry.
  """

  @enforce_keys [:code_hash, :client_id, :redirect_uri, :scope, :expires_at]
  defstruct [
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

  @type t :: %__MODULE__{
          code_hash: String.t(),
          client_id: String.t(),
          redirect_uri: String.t(),
          challenge: String.t() | nil,
          challenge_method: String.t() | nil,
          scope: String.t(),
          sub: String.t() | nil,
          resource: String.t() | nil,
          expires_at: DateTime.t()
        }
end
