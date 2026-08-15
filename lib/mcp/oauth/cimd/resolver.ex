defmodule MCP.OAuth.CIMD.Resolver do
  @moduledoc """
  Fetches, validates, and caches a Client ID Metadata Document from an https
  `client_id` URL (draft-ietf-oauth-client-id-metadata-document).

  Zero OAuth coupling on purpose: this is "fetch a JSON document from a URL,
  safely" plus a TTL cache. `MCP.OAuth.CIMD` is the only module that turns a
  `MCP.OAuth.CIMD.Document` into a `MCP.OAuth.Client`.

  SSRF posture (the whole risk of "the client_id is a URL we fetch"):

    * https only — enforced before any DNS lookup happens.
    * port pinned to the configured `:allowed_port` (default 443).
    * `MCP.OAuth.CIMD.SSRF.resolve_public_address/1` resolves DNS once and
      rejects private/loopback/link-local/multicast/metadata addresses; the
      transport then connects to that exact resolved address (see
      `MCP.OAuth.CIMD.ReqTransport`) so a second DNS lookup at connect time
      can't swap in a private address (DNS rebinding).
    * redirects are NOT auto-followed by the transport — each hop is
      re-validated (https, port, SSRF) through this same module, capped at
      `:max_redirects`.
    * response body is capped at `:max_response_bytes`, enforced while
      streaming (not after buffering).
    * both connect and receive are bounded by `:request_timeout_ms`, so a
      slow or hanging client_id host can't stall the caller (e.g. the token
      endpoint) waiting on it.

  Options (all optional, defaults in parentheses):

    * `:transport` — a `MCP.OAuth.CIMD.Transport` (`ReqTransport`)
    * `:cache` — a cache module, or `false` to disable (`CIMD.Cache`)
    * `:cache_opts` — forwarded to the cache module (`[]`)
    * `:cache_ttl_ms` (300_000), `:request_timeout_ms` (3_000),
      `:max_redirects` (3), `:max_response_bytes` (65_536),
      `:allowed_port` (443)
  """

  require Logger

  alias MCP.OAuth.CIMD.{Cache, Document, SSRF}

  @default_cache_ttl_ms 300_000
  @default_timeout_ms 3_000
  @default_max_redirects 3
  @default_max_response_bytes 65_536
  @default_allowed_port 443

  @type reason ::
          :not_https
          | :disallowed_port
          | :unresolvable
          | {:disallowed_address, :inet.ip_address()}
          | :too_many_redirects
          | :response_too_large
          | :fetch_failed
          | :invalid_status
          | :invalid_document
          | :client_id_mismatch

  @doc "Resolves `client_id` (a CIMD https URL) to its document, cache-first."
  @spec resolve(String.t(), keyword()) :: {:ok, Document.t()} | {:error, reason()}
  def resolve(client_id, opts \\ [])

  def resolve(client_id, opts) when is_binary(client_id) do
    case cached(client_id, opts) do
      %Document{} = document -> {:ok, document}
      nil -> fetch_and_cache(client_id, opts)
    end
  end

  def resolve(_client_id, _opts), do: {:error, :not_https}

  defp cached(client_id, opts) do
    case Keyword.get(opts, :cache, Cache) do
      false -> nil
      cache -> cache.get(client_id, Keyword.get(opts, :cache_opts, []))
    end
  end

  defp cache(client_id, document, opts) do
    case Keyword.get(opts, :cache, Cache) do
      false ->
        :ok

      cache ->
        ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
        cache.put(client_id, document, ttl, Keyword.get(opts, :cache_opts, []))
    end
  end

  defp fetch_and_cache(client_id, opts) do
    # Validates against the originally-requested client_id, not wherever a redirect ended up.
    with {:ok, json} <- fetch(client_id, max_redirects(opts), opts),
         {:ok, document} <- Document.parse(client_id, json) do
      cache(client_id, document, opts)
      {:ok, document}
    else
      {:error, reason} = error ->
        Logger.info(
          "MCP.OAuth.CIMD fetch failed client_id=#{client_id} reason=#{inspect(reason)}"
        )

        error
    end
  end

  defp fetch(_url, 0, _opts), do: {:error, :too_many_redirects}

  defp fetch(url, redirects_remaining, opts) do
    with %URI{scheme: "https", host: host, port: port} = uri when is_binary(host) and host != "" <-
           URI.parse(url),
         :ok <- validate_port(port, opts),
         {:ok, address} <- SSRF.resolve_public_address(host),
         {:ok, resp} <-
           transport(opts).fetch(uri, address,
             max_response_bytes: max_response_bytes(opts),
             timeout_ms: timeout_ms(opts)
           ) do
      handle_response(resp, uri, redirects_remaining, opts)
    else
      %URI{} -> {:error, :not_https}
      # The rejected address rides along: which private range a client_id
      # resolved to is the whole story when this fires in production.
      {:error, _reason} = error -> error
    end
  end

  defp validate_port(port, opts) do
    if port == allowed_port(opts), do: :ok, else: {:error, :disallowed_port}
  end

  defp handle_response(%{status: status, headers: headers}, uri, redirects_remaining, opts)
       when status in [301, 302, 303, 307, 308] do
    case List.keyfind(headers, "location", 0) do
      {"location", location} ->
        uri
        |> URI.merge(location)
        |> URI.to_string()
        |> fetch(redirects_remaining - 1, opts)

      nil ->
        {:error, :fetch_failed}
    end
  end

  defp handle_response(%{status: 200, body: body}, _uri, _redirects_remaining, _opts) do
    case Jason.decode(body) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, :invalid_document}
    end
  end

  defp handle_response(_resp, _uri, _redirects_remaining, _opts), do: {:error, :invalid_status}

  defp transport(opts), do: Keyword.get(opts, :transport, MCP.OAuth.CIMD.ReqTransport)
  defp timeout_ms(opts), do: Keyword.get(opts, :request_timeout_ms, @default_timeout_ms)
  defp max_redirects(opts), do: Keyword.get(opts, :max_redirects, @default_max_redirects)

  defp max_response_bytes(opts),
    do: Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

  defp allowed_port(opts), do: Keyword.get(opts, :allowed_port, @default_allowed_port)
end
