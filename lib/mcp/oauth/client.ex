defmodule MCP.OAuth.Client do
  @moduledoc """
  A registered OAuth client, as the host app's `MCP.OAuth.Store` returns it.

  `secret_hash: nil` marks a public client — no client authentication at the
  token endpoint, PKCE mandatory. `confidential?` is asserted independently
  rather than derived from `secret_hash`, so a store can reject a
  confidential client that was seeded without a secret instead of silently
  treating it as public.

  `name`, `client_uri`, and `logo_uri` are RFC 7591 client metadata, carried
  so a consent screen can name the app asking. `dynamically_registered?`
  separates a client that self-registered through
  `MCP.OAuth.Plug.Register` from one an operator issued by hand: nothing
  vouches for the former beyond its own claims, and a consent screen has to
  be able to say so.

  `cimd?` narrows that further: the client was identified by an https URL it
  serves its own metadata from (`MCP.OAuth.CIMD`) rather than by an id this
  server issued. Still self-asserted, but asserted at a domain the client
  controls, which is a different sentence for a consent screen to write.
  """

  @enforce_keys [:id, :redirect_uris, :scopes, :grant_types, :confidential?, :pkce_required?]
  defstruct [
    :id,
    :secret_hash,
    :redirect_uris,
    :scopes,
    :grant_types,
    :confidential?,
    :pkce_required?,
    :name,
    :client_uri,
    :logo_uri,
    dynamically_registered?: false,
    cimd?: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          secret_hash: String.t() | nil,
          redirect_uris: [String.t()],
          scopes: [String.t()],
          grant_types: [String.t()],
          confidential?: boolean(),
          pkce_required?: boolean(),
          name: String.t() | nil,
          client_uri: String.t() | nil,
          logo_uri: String.t() | nil,
          dynamically_registered?: boolean(),
          cimd?: boolean()
        }
end
