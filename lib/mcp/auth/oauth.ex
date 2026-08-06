defmodule MCP.Auth.OAuth do
  @moduledoc """
  `MCP.Auth` backed by the built-in `MCP.OAuth` server: the ready-made verifier
  for an app that mounts `MCP.OAuth.Plug.*` as its own authorization server.

  Verification is a local store lookup, not introspection over HTTP, because the
  AS and the resource server are the same app. The `:resource` option is the RFC
  8707 audience enforced on every token, so a token minted for another resource
  is refused here, not merely undocumented.

      auth: {MCP.Auth.OAuth,
             store: MyApp.OAuth.Store,
             resource: MyApp.OAuth.mcp_resource(),
             base_url: {MyAppWeb.Endpoint, :url, []}}

  Options:

    * `:store` — a `MCP.OAuth.Store` (required)
    * `:resource` — the audience every token must carry; a string or an
      `{m, f, a}`. Omit to accept any audience.
    * `:base_url` — origin the 401 metadata pointer is built from; see `MCP.URL`
  """

  @behaviour MCP.Auth

  @impl MCP.Auth
  def verify(_conn, token, opts) do
    store = Keyword.fetch!(opts, :store)

    case MCP.OAuth.verify_token(store, token, resolve(opts[:resource])) do
      {:ok, result} -> {:ok, %MCP.Context{principal: result.principal, scopes: result.scopes}}
      {:error, :invalid_token} -> {:error, :invalid_token}
    end
  end

  @impl MCP.Auth
  def resource_metadata_url(conn, opts),
    do: MCP.URL.metadata_url(conn, opts[:base_url], MCP.URL.mount_path(conn))

  defp resolve(nil), do: nil
  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
