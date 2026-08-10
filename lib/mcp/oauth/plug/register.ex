defmodule MCP.OAuth.Plug.Register do
  @moduledoc """
  The RFC 7591 dynamic client registration endpoint as a mountable plug.

  Mount it in a plain JSON pipeline — this is an unauthenticated,
  sessionless POST, and it takes no initial access token because MCP clients
  do not send one:

      forward "/oauth/register", MCP.OAuth.Plug.Register,
        store: MyApp.OAuth.Store,
        scopes: {MyApp.OAuth, :scope_names, []},
        rate_limit: {MyApp.RateLimiter, :check, [limit: 20, window_ms: 3_600_000]}

  Open registration is only safe behind a consent screen. See
  `MCP.OAuth.Plug.Authorize`'s `:consent` option: without one, anyone who can
  reach this endpoint can register a client with their own redirect_uri and
  walk a signed-in resource owner into handing it a code.

  `MCP.OAuth.Registration` decides what a registration may contain; this plug
  is the transport, the rate limit, and the store write.

  Options:

    * `:store` — a `MCP.OAuth.Store`; `put_client/1` is the only callback used
      (required)
    * `:scopes` — the scopes a registration may request; a list or an
      `{m, f, a}` (default `[]`)
    * `:rate_limit` — `{module, function, opts}`, called as
      `module.function(key, opts)` per request and expected to return `:ok` or
      `{:error, :rate_limited, retry_after_ms}`. The key is the peer IP.
      Omitted means no limit, which is a choice, not a default worth taking on
      an endpoint that writes a row per call.

  A note on that limit: an ETS-backed limiter is per-node, so on a multi-task
  deployment the effective ceiling is the configured limit times the task
  count, and a client that lands on a different task starts fresh. That is
  enough to stop a single host hammering one node; it is not a global budget,
  and it wants a shared counter before this endpoint carries real volume.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  alias MCP.OAuth.Registration

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      scopes: Keyword.get(opts, :scopes, []),
      rate_limit: Keyword.get(opts, :rate_limit)
    }
  end

  @impl Plug
  def call(%{method: "POST"} = conn, config) do
    conn = no_store(conn)

    case check_rate(conn, config.rate_limit) do
      :ok -> register(conn, config)
      {:error, retry_after_ms} -> rate_limited(conn, retry_after_ms)
    end
  end

  def call(conn, _config) do
    conn
    |> put_resp_header("allow", "POST")
    |> json(405, %{
      "error" => "invalid_request",
      "error_description" => "client registration is POST only"
    })
  end

  defp register(conn, config) do
    with {:ok, metadata} <- body(conn),
         {:ok, client} <- Registration.build(metadata, scopes: resolve(config.scopes)) do
      store(conn, config, client)
    else
      {:error, {code, description}} ->
        json(conn, 400, %{"error" => code, "error_description" => description})
    end
  end

  defp store(conn, config, client) do
    case config.store.put_client(client) do
      :ok ->
        json(conn, 201, Registration.response(client, System.system_time(:second)))

      # Logged, not returned: the reason is a store-shaped value and the caller
      # is unauthenticated.
      {:error, reason} ->
        Logger.error("OAuth client registration could not be stored: #{inspect(reason)}")

        json(conn, 500, %{
          "error" => "server_error",
          "error_description" => "the client could not be registered"
        })
    end
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params),
    do: {:ok, params}

  defp body(_conn),
    do:
      {:error,
       {"invalid_client_metadata", "the request body must be JSON with a JSON content-type"}}

  defp check_rate(_conn, nil), do: :ok

  defp check_rate(conn, {module, function, opts}) do
    case apply(module, function, [peer(conn), opts]) do
      :ok -> :ok
      {:error, :rate_limited, retry_after_ms} -> {:error, retry_after_ms}
    end
  end

  defp peer(%{remote_ip: ip}) when is_tuple(ip),
    do: "oauth-register:" <> to_string(:inet.ntoa(ip))

  defp peer(_conn), do: "oauth-register:unknown"

  defp rate_limited(conn, retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
    |> json(429, %{
      "error" => "temporarily_unavailable",
      "error_description" => "too many registrations from this address"
    })
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  # RFC 7591 §3.2: registration responses carry a credential-shaped identifier.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
