defmodule MCP.OAuth.Plug.Token do
  @moduledoc """
  The OAuth token, introspection, and revocation endpoints (RFC 6749 §3.2,
  RFC 7662, RFC 7009) as one mountable plug, selected by `:action`.

  These are credentialed, sessionless POSTs, so mount them in a plain JSON
  pipeline with no session or CSRF:

      forward "/oauth/token", MCP.OAuth.Plug.Token, store: MyApp.OAuth.Store
      forward "/oauth/introspect", MCP.OAuth.Plug.Token,
        action: :introspect, store: MyApp.OAuth.Store, issuer: MyApp.OAuth.issuer()
      forward "/oauth/revoke", MCP.OAuth.Plug.Token,
        action: :revoke, store: MyApp.OAuth.Store

  Options:

    * `:store` — a `MCP.OAuth.Store` (required)
    * `:action` — `:token` (default), `:introspect`, or `:revoke`
    * `:default_resource` — for `:token`, the RFC 8707 resource to bind to when
      the request omits one; a string or an `{m, f, a}`
    * `:issuer` — for `:introspect`, the `iss` stamped on an active response; a
      string or an `{m, f, a}`
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      action: Keyword.get(opts, :action, :token),
      default_resource: Keyword.get(opts, :default_resource),
      issuer: Keyword.get(opts, :issuer)
    }
  end

  @impl Plug
  def call(conn, config) do
    conn = no_store(conn)
    params = conn.body_params

    case config.action do
      :token -> handle_token(conn, config, params)
      :introspect -> handle_introspect(conn, config, params)
      :revoke -> handle_revoke(conn, config, params)
    end
  end

  defp handle_token(conn, config, params) do
    params = put_default_resource(params, config.default_resource)

    case MCP.OAuth.token(config.store, params) do
      {:ok, response} -> json(conn, 200, compact(response))
      {:error, %{status: status} = error} -> json(conn, status, error_body(error))
    end
  end

  defp handle_introspect(conn, config, params) do
    case MCP.OAuth.introspect(config.store, params) do
      %{active: true} = result -> json(conn, 200, compact(with_issuer(result, config.issuer)))
      %{active: false} = result -> json(conn, 200, result)
    end
  end

  defp handle_revoke(conn, config, params) do
    :ok = MCP.OAuth.revoke(config.store, params)
    send_resp(conn, 200, "")
  end

  defp with_issuer(result, nil), do: result
  defp with_issuer(result, issuer), do: Map.put(result, :iss, resolve(issuer))

  defp put_default_resource(params, nil), do: params

  defp put_default_resource(params, resource),
    do: Map.put_new(params, "resource", resolve(resource))

  defp error_body(%{error: error, error_description: description}),
    do: %{error: error, error_description: description}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  # RFC 6749 §5.1: token responses must not be cached anywhere.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
