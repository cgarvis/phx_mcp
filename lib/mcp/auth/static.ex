defmodule MCP.Auth.Static do
  @moduledoc """
  Static token map for dev/test: `token => {principal, scopes}`.

  Tokens come from the adapter opts (`tokens:`) or from
  `config <otp_app>, MCP.Auth.Static, tokens: %{...}` where `otp_app:` is an
  adapter opt naming the host app (default `:phx_mcp`). No config means every
  token is rejected, so mounting this adapter unconfigured denies all requests.

  `base_url:` is the origin the 401's metadata pointer is built from; see
  `MCP.URL`.
  """

  @behaviour MCP.Auth

  @impl MCP.Auth
  def verify(_conn, token, opts) do
    case Map.fetch(tokens(opts), token) do
      {:ok, {principal, scopes}} -> {:ok, %MCP.Context{principal: principal, scopes: scopes}}
      :error -> {:error, :invalid_token}
    end
  end

  @impl MCP.Auth
  def resource_metadata_url(conn, opts) do
    base = opts[:base_url] || config(opts)[:base_url]
    MCP.URL.metadata_url(conn, base, MCP.URL.mount_path(conn))
  end

  defp tokens(opts), do: opts[:tokens] || config(opts)[:tokens] || %{}

  defp config(opts), do: Application.get_env(opts[:otp_app] || :phx_mcp, __MODULE__, [])
end
