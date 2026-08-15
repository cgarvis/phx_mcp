defmodule MCP.Legacy do
  @moduledoc """
  Pre-2026-07-28 handshake support, quarantined in one file so it can be
  deleted in one piece.

  Every shipping client opens a connection with the `initialize` handshake and
  omits the `_meta` envelope `MCP.RPC.negotiate_version/1` requires. That
  includes clients which implement 2026-07-28 and probe legacy-first, so
  without this module a 2026-07-28-only server is unreachable by all of them,
  not merely by old ones.

  Three things are needed to answer that handshake, and all three live here:

    * `initialize` gets a reply built from the server's own capabilities.
    * `notifications/initialized`, which the client sends next, carries no `id`
      and expects no body.
    * `ping` keepalives, which the server has no method for.
    * Every later request arrives without the `_meta` envelope, so the current
      protocol version is stamped on before the pipeline sees it.

  Nothing outside this module learns that a second dialect exists.

  To remove: delete this file, then in `MCP.Plug` delete the private
  `dispatch_body/4` and rename the private `dispatch_request/4` to take its
  place.
  """

  alias MCP.RPC

  # Duplicated rather than imported from MCP.RPC so removal touches one file.
  @version_key "io.modelcontextprotocol/protocolVersion"

  # Revisions this shim will settle on. The method surface it forwards to
  # (tools/*, resources/*, prompts/*) is unchanged across them.
  @versions ["2025-11-25", "2025-06-18"]
  @fallback "2025-06-18"

  @doc """
  Normalizes a decoded JSON-RPC body into something the 2026-07-28 pipeline
  accepts.

    * `{:cont, body}` — pass to `MCP.RPC.parse/1` as usual
    * `{:halt, status, payload}` — answered here; a `nil` payload means an
      empty response body

  A body that already carries the `_meta` protocol version is returned
  untouched, so modern clients never take a different path.
  """
  def adapt(body, server)

  def adapt(%{"method" => "initialize", "id" => id} = body, server) when id != nil do
    {:halt, 200, RPC.result_response(id, initialize_result(body, server))}
  end

  # Keepalive. A failed ping reads as a dead connection, not an absent feature.
  def adapt(%{"method" => "ping", "id" => id}, _server) when id != nil do
    {:halt, 200, RPC.result_response(id, %{})}
  end

  def adapt(%{"method" => "notifications/" <> _}, _server), do: {:halt, 202, nil}

  def adapt(body, _server) when is_map(body), do: {:cont, stamp(body)}

  def adapt(body, _server), do: {:cont, body}

  defp initialize_result(body, server) do
    %{
      "protocolVersion" => negotiated(body),
      "capabilities" => server.discover_payload()["capabilities"],
      "serverInfo" => server.server_info()
    }
  end

  # Echo the client's revision when we speak it; otherwise name ours and let it decide.
  defp negotiated(%{"params" => %{"protocolVersion" => version}}) when version in @versions,
    do: version

  defp negotiated(_body), do: @fallback

  defp stamp(body) do
    case Map.get(body, "params") do
      nil ->
        Map.put(body, "params", %{"_meta" => %{@version_key => MCP.protocol_version()}})

      params when is_map(params) ->
        Map.put(body, "params", stamp_params(params))

      # Malformed params are RPC.parse/1's to reject, not ours to rewrite.
      _ ->
        body
    end
  end

  defp stamp_params(params) do
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}

    if is_binary(meta[@version_key]) and meta[@version_key] != "" do
      params
    else
      Map.put(params, "_meta", Map.put(meta, @version_key, MCP.protocol_version()))
    end
  end
end
