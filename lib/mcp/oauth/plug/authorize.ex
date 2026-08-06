defmodule MCP.OAuth.Plug.Authorize do
  @moduledoc """
  The OAuth authorization endpoint (RFC 6749 §3.1) as a mountable plug.

  Mount it in a pipeline that has already established the application session:
  the resource owner is resolved from the request's own login through the
  `:resource_owner` module (see `MCP.OAuth.ResourceOwner`). A signed-out request
  is redirected to `:sign_in_path`; there is no consent screen, so reaching this
  endpoint signed in is itself the grant.

      forward "/oauth/authorize", MCP.OAuth.Plug.Authorize,
        store: MyApp.OAuth.Store,
        resource_owner: MyApp.OAuth.ResourceOwner,
        sign_in_path: "/sign-in"

  Options:

    * `:store` — a `MCP.OAuth.Store` (required)
    * `:resource_owner` — a `MCP.OAuth.ResourceOwner` (required)
    * `:sign_in_path` — where a signed-out request is sent (required)
    * `:default_resource` — an RFC 8707 resource to bind the code to when the
      request omits one; a string or an `{m, f, a}` resolved per request
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      resource_owner: Keyword.fetch!(opts, :resource_owner),
      sign_in_path: Keyword.fetch!(opts, :sign_in_path),
      default_resource: Keyword.get(opts, :default_resource)
    }
  end

  @impl Plug
  def call(conn, config) do
    conn = fetch_query_params(conn)
    owner = config.resource_owner

    with {:ok, subject} <- owner.current_subject(conn),
         {:ok, subject} <- owner.fetch(subject) do
      params = put_default_resource(conn.query_params, config.default_resource)

      case MCP.OAuth.authorize(config.store, params, subject) do
        {:ok, %{redirect_uri: uri, query: query}} -> redirect(conn, uri, query)
        {:error, {:invalid_redirect, reason}} -> invalid_request(conn, reason)
        {:error, {:redirect, uri, query}} -> redirect(conn, uri, query)
      end
    else
      _ -> redirect(conn, config.sign_in_path)
    end
  end

  defp put_default_resource(params, nil), do: params

  defp put_default_resource(params, resource),
    do: Map.put_new(params, "resource", resolve(resource))

  defp redirect(conn, uri, query),
    do: redirect(conn, uri <> "?" <> URI.encode_query(compact(query)))

  defp redirect(conn, url) do
    conn |> put_resp_header("location", url) |> send_resp(302, "") |> halt()
  end

  defp invalid_request(conn, reason) do
    body = %{error: "invalid_request", error_description: to_string(reason)}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(body))
    |> halt()
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
