defmodule MCP.OAuth.Client do
  @moduledoc """
  A registered OAuth client, as the host app's `MCP.OAuth.Store` returns it.

  `secret_hash: nil` marks a public client — no client authentication at the
  token endpoint, PKCE mandatory. `confidential?` is asserted independently
  rather than derived from `secret_hash`, so a store can reject a
  confidential client that was seeded without a secret instead of silently
  treating it as public.
  """

  @enforce_keys [:id, :redirect_uris, :scopes, :grant_types, :confidential?, :pkce_required?]
  defstruct [
    :id,
    :secret_hash,
    :redirect_uris,
    :scopes,
    :grant_types,
    :confidential?,
    :pkce_required?
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          secret_hash: String.t() | nil,
          redirect_uris: [String.t()],
          scopes: [String.t()],
          grant_types: [String.t()],
          confidential?: boolean(),
          pkce_required?: boolean()
        }
end
