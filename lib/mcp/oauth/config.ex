defmodule MCP.OAuth.Config do
  @moduledoc """
  Runtime lookup for the authorization server's identity, configured as

      config :my_app, MCP.OAuth,
        store: MyApp.OAuth.Store,
        resource_owner: MyApp.OAuth.ResourceOwner,
        consent: MyAppWeb.OAuth.Consent,
        issuer: "https://api.example.com",
        scopes: {MyApp.OAuth, :scope_names, []},
        default_resource: {MyApp.OAuth, :mcp_resource, []}

  `MCP.Router.mcp_oauth/2` reads this config, keyed by the `MCP.OAuth` module
  under the host's `otp_app`, for whichever of these six identity values the
  call site did not pass explicitly.

  This module exists because `forward` calls a plug's `init/1` at compile time.
  A value read straight out of `Application.get_env/2` while `mcp_oauth/2` is
  expanding (the router's own compile time) gets baked into the router's
  bytecode, and a `runtime.exs` override of it would then silently do
  nothing in production. `store`, `resource_owner`, and `consent` are module
  names, not meaningfully swappable without a deploy either way, so
  `mcp_oauth/2` resolves those directly while it expands. `issuer`, `scopes`,
  and `default_resource` are the values most likely to differ by environment,
  so instead of resolving them, `mcp_oauth/2` passes `{MCP.OAuth.Config,
  :fetch, [otp_app, key]}` as the plug option. Every plug in this library
  that accepts such an option already resolves `{m, f, a}` tuples inside
  `call/2`, once per request, so this lookup runs on every request rather
  than once at compile time. `MCP.Plug.WellKnown` does the equivalent thing
  for `:authorization_servers` already; see its moduledoc.

  A config value may itself be an `{m, f, a}` tuple, exactly as
  `default_resource` is in the example above; `fetch/2` resolves one level
  of that too, so the double indirection (macro default -> config lookup ->
  host MFA) collapses to the host's actual value with no extra work at any
  call site.
  """

  @doc false
  @spec fetch(atom(), atom()) :: term()
  def fetch(otp_app, key) do
    otp_app
    |> Application.get_env(MCP.OAuth, [])
    |> Keyword.get(key)
    |> resolve()
  end

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
