defmodule MCP.Plug.WellKnown do
  @moduledoc """
  Serves the OAuth protected-resource metadata document (RFC 9728).

  Forwarded, the usual way, from inside a router:

      forward "/.well-known/oauth-protected-resource", MCP.Plug.WellKnown,
        otp_app: :my_app,
        base_url: {MyAppWeb.Endpoint, :url, []},
        resource: "/mcp"

  Or mounted directly in `endpoint.ex`, ahead of the router, with `mount: :endpoint`:

      plug MCP.Plug.WellKnown, otp_app: :my_app, resource: "/mcp", mount: :endpoint

  The endpoint form exists because `/.well-known/oauth-protected-resource` is a
  path fixed by the RFC, not app code. Forwarded from inside a `scope`, it
  answers at `<scope prefix>/.well-known/oauth-protected-resource` instead of
  the RFC's absolute path, which 404s every client and has no local symptom:
  the app still answers at whatever path was actually configured, so a
  developer testing that exact path sees success. Mounting in `endpoint.ex`,
  above any scope, sidesteps the whole class of mistake.

  `:resource` is the path the MCP endpoint is mounted at; the document names it
  absolutely against `:base_url` (see `MCP.URL`), and the plug answers at both
  the bare mount and the §3.1 path-inserted sub-path. `:authorization_servers` is a
  list of issuer URLs, from the opts or from
  `config <otp_app>, MCP.Plug.WellKnown, authorization_servers: [...]`, read per
  request so runtime config applies. The document shape is the RFC's, so the
  kernel builds it rather than asking the host app for a map.

  ## `:mount`

  `:forward` (default) or `:endpoint`.

  As a forwarded plug, Phoenix has already matched `/.well-known/oauth-protected-resource`
  and stripped it into `script_name`; `conn.path_info` holds only what comes
  after it, so a non-matching path is unambiguously a 404 (nothing else could
  answer it, since forward gave this plug that whole subtree).

  As an endpoint plug, `conn.path_info` is the full, unrouted path: most
  requests reaching it are not ours at all. `:endpoint` mode checks whether
  `path_info` starts with the fixed `.well-known/oauth-protected-resource`
  prefix; if it doesn't, the conn passes through untouched (not halted, not
  404'd) so the endpoint pipeline and the router still run. If it does, the
  prefix is stripped and matched exactly as in `:forward` mode. These two
  outcomes are genuinely different behaviors for the same path (compare a
  bare `/` in each mode: forwarded, it is the resource's bare mount and a
  200; as an endpoint plug, `/` is almost certainly some other page, and
  claiming it would be a bug), which is why the mode has to be explicit
  rather than guessed from `conn` alone.
  """

  @behaviour Plug

  import Plug.Conn

  # RFC 9728: fixed by the spec, not derived from any option. This is what
  # `:endpoint` mode looks for in the full, unrouted path_info.
  @well_known_prefix [".well-known", "oauth-protected-resource"]

  @impl Plug
  def init(opts) do
    resource = Keyword.fetch!(opts, :resource)
    mount = Keyword.get(opts, :mount, :forward)

    unless mount in [:forward, :endpoint] do
      raise ArgumentError,
            "MCP.Plug.WellKnown :mount must be :forward or :endpoint, got: #{inspect(mount)}"
    end

    %{
      resource: resource,
      resource_segments: String.split(resource, "/", trim: true),
      base_url: opts[:base_url],
      otp_app: Keyword.get(opts, :otp_app, :phx_mcp),
      authorization_servers: opts[:authorization_servers],
      mount: mount
    }
  end

  @impl Plug
  def call(conn, %{mount: :endpoint} = config) do
    case strip_prefix(conn.path_info, @well_known_prefix) do
      {:ok, rest} -> respond(conn, rest, config)
      # Not our absolute path at all; some other plug or route owns it.
      :error -> conn
    end
  end

  def call(conn, config), do: respond(conn, conn.path_info, config)

  defp respond(conn, path_info, config) do
    cond do
      not serves?(path_info, config) -> conn |> send_resp(404, "") |> halt()
      conn.method == "GET" -> send_document(conn, config)
      true -> conn |> put_resp_header("allow", "GET") |> send_resp(405, "") |> halt()
    end
  end

  # RFC 9728 §3.1 puts the resource's path after the well-known segment. Clients
  # that skip the insertion ask for the bare path; both name the same resource.
  defp serves?([], _config), do: true
  defp serves?(path, config), do: path == config.resource_segments

  defp strip_prefix(path_info, prefix) do
    if List.starts_with?(path_info, prefix) do
      {:ok, Enum.drop(path_info, length(prefix))}
    else
      :error
    end
  end

  defp send_document(conn, config) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(document(conn, config)))
    |> halt()
  end

  defp document(conn, config) do
    %{
      "resource" => MCP.URL.join(conn, config.base_url, config.resource),
      "authorization_servers" => authorization_servers(config)
    }
  end

  defp authorization_servers(%{authorization_servers: servers}) when is_list(servers), do: servers

  defp authorization_servers(config),
    do: Application.get_env(config.otp_app, __MODULE__, [])[:authorization_servers] || []
end
