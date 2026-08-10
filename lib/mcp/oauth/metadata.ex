defmodule MCP.OAuth.Metadata do
  @moduledoc """
  RFC 8414 authorization server metadata document — no OIDC fields, no `jwks_uri`.
  """

  @doc """
  Builds the metadata map for `issuer`.

  Endpoint paths default to the conventional `/authorize`, `/token`,
  `/introspect`, `/revoke` suffixes; pass `:authorization_endpoint` etc. in
  `opts` to override where the host app actually mounts them.
  `opts[:scopes]` becomes `scopes_supported` (default `[]`).

  `registration_endpoint` is the one field that is opt-in rather than
  defaulted: an advertised registration endpoint is a promise that clients
  act on immediately, so it appears only when the host passes
  `:registration_endpoint`, having actually mounted
  `MCP.OAuth.Plug.Register`.
  """
  @spec document(String.t(), keyword()) :: map()
  def document(issuer, opts \\ []) do
    issuer = String.trim_trailing(issuer, "/")

    opts
    |> Keyword.get(:registration_endpoint)
    |> put_registration_endpoint(%{
      "issuer" => issuer,
      "authorization_endpoint" =>
        Keyword.get(opts, :authorization_endpoint, issuer <> "/authorize"),
      "token_endpoint" => Keyword.get(opts, :token_endpoint, issuer <> "/token"),
      "introspection_endpoint" =>
        Keyword.get(opts, :introspection_endpoint, issuer <> "/introspect"),
      "revocation_endpoint" => Keyword.get(opts, :revocation_endpoint, issuer <> "/revoke"),
      "scopes_supported" => Keyword.get(opts, :scopes, []),
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token", "client_credentials"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => [
        "none",
        "client_secret_basic",
        "client_secret_post"
      ]
    })
  end

  defp put_registration_endpoint(nil, document), do: document

  defp put_registration_endpoint(url, document),
    do: Map.put(document, "registration_endpoint", url)
end
