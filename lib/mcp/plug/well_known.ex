defmodule MCP.Plug.WellKnown do
  @moduledoc """
  Serves the OAuth protected-resource metadata document (RFC 9728).

      forward "/.well-known/oauth-protected-resource", MCP.Plug.WellKnown,
        otp_app: :my_app,
        base_url: {MyAppWeb.Endpoint, :url, []},
        resource: "/mcp"

  `:resource` is the path the MCP endpoint is mounted at; the document names it
  absolutely against `:base_url` (see `MCP.URL`), and the plug answers at both
  the bare mount and the §3.1 path-inserted sub-path. `:authorization_servers` is a
  list of issuer URLs, from the opts or from
  `config <otp_app>, MCP.Plug.WellKnown, authorization_servers: [...]`, read per
  request so runtime config applies. The document shape is the RFC's, so the
  kernel builds it rather than asking the host app for a map.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    resource = Keyword.fetch!(opts, :resource)

    %{
      resource: resource,
      resource_segments: String.split(resource, "/", trim: true),
      base_url: opts[:base_url],
      otp_app: Keyword.get(opts, :otp_app, :mcp),
      authorization_servers: opts[:authorization_servers]
    }
  end

  @impl Plug
  def call(conn, config) do
    cond do
      not serves?(conn, config) -> conn |> send_resp(404, "") |> halt()
      conn.method == "GET" -> send_document(conn, config)
      true -> conn |> put_resp_header("allow", "GET") |> send_resp(405, "") |> halt()
    end
  end

  # RFC 9728 §3.1 puts the resource's path after the well-known segment. Clients
  # that skip the insertion ask for the bare path; both name the same resource.
  defp serves?(%Plug.Conn{path_info: []}, _config), do: true
  defp serves?(%Plug.Conn{path_info: path}, config), do: path == config.resource_segments

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
