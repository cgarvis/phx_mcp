defmodule MCP.URL do
  @moduledoc """
  Origin resolution for the two URLs the protocol puts on the wire: the
  canonical resource identifier and the protected-resource metadata pointer.

  Hosts pass `base_url:` as a string or an `{m, f, a}` resolved per request;
  Phoenix apps pass `{MyAppWeb.Endpoint, :url, []}`. Omitting it derives the
  origin from the request itself, which is right in dev and wrong behind a
  proxy that terminates TLS, so anything with a canonical hostname passes it.

  Paths belong to the kernel: `/.well-known/oauth-protected-resource` is fixed
  by RFC 9728, and the mount path is a router fact, so neither is app code.
  """

  @metadata_path "/.well-known/oauth-protected-resource"

  @type base :: String.t() | mfa() | nil

  @doc """
  The RFC 9728 protected-resource metadata URL for a resource path.

  §3.1 inserts the well-known segment between host and path, so a resource
  mounted at `/mcp` publishes at `/.well-known/oauth-protected-resource/mcp`.
  """
  @spec metadata_url(Plug.Conn.t(), base, String.t()) :: String.t()
  def metadata_url(conn, base, resource_path \\ "/")

  def metadata_url(conn, base, "/" <> _ = resource_path),
    do: origin(conn, base) <> @metadata_path <> String.trim_trailing(resource_path, "/")

  @doc "Joins an absolute path onto the resolved origin."
  @spec join(Plug.Conn.t(), base, String.t()) :: String.t()
  def join(conn, base, "/" <> _ = path), do: origin(conn, base) <> path

  @doc """
  The path a forwarded plug is mounted at, which is the resource's own path.

  Inside a `forward`, Plug moves the consumed segments to `script_name`.
  """
  @spec mount_path(Plug.Conn.t()) :: String.t()
  def mount_path(%Plug.Conn{script_name: []}), do: "/"
  def mount_path(%Plug.Conn{script_name: segments}), do: "/" <> Enum.join(segments, "/")

  defp origin(conn, nil), do: from_request(conn)
  defp origin(conn, {mod, fun, args}), do: origin(conn, apply(mod, fun, args))
  defp origin(_conn, url) when is_binary(url), do: String.trim_trailing(url, "/")

  defp from_request(%Plug.Conn{scheme: scheme, host: host, port: port}),
    do: "#{scheme}://#{host}#{port_suffix(scheme, port)}"

  defp port_suffix(:https, 443), do: ""
  defp port_suffix(:http, 80), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
