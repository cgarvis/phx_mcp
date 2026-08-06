defmodule MCP.OAuth.Plug.Metadata do
  @moduledoc """
  RFC 8414 authorization server metadata as a mountable plug, served at
  `/.well-known/oauth-authorization-server`.

      forward "/.well-known/oauth-authorization-server", MCP.OAuth.Plug.Metadata,
        issuer: MyApp.OAuth.issuer(), scopes: MyApp.OAuth.scope_names()

  Options:

    * `:issuer` — the exact-match issuer identifier; a string or an `{m, f, a}`
      (required). Every endpoint URL is built from it, not from the request, so
      a document cannot describe an origin other than the issuer's.
    * `:scopes` — `scopes_supported`; a list or an `{m, f, a}` (default `[]`)
    * `:base_path` — the prefix the endpoints are mounted under (default
      `"/oauth"`), so the document names where they actually live
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      issuer: Keyword.fetch!(opts, :issuer),
      scopes: Keyword.get(opts, :scopes, []),
      base_path: Keyword.get(opts, :base_path, "/oauth")
    }
  end

  @impl Plug
  def call(conn, config) do
    issuer = resolve(config.issuer)
    base = issuer <> config.base_path

    document =
      MCP.OAuth.Metadata.document(issuer,
        scopes: resolve(config.scopes),
        authorization_endpoint: base <> "/authorize",
        token_endpoint: base <> "/token",
        introspection_endpoint: base <> "/introspect",
        revocation_endpoint: base <> "/revoke"
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(document))
    |> halt()
  end

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
