defmodule MCP.OAuth.CIMD.ReqTransport do
  @moduledoc """
  Production `MCP.OAuth.CIMD.Transport`: connects to the pre-resolved,
  SSRF-validated `address` directly (not the hostname) so a second DNS
  lookup at connect time can't swap in a different, private address (DNS
  rebinding) — `connect_options: hostname:` pins TLS SNI/certificate
  verification to the original hostname while the socket targets the pinned
  IP. Response body is capped while streaming via `:into`, not after
  buffering, so a large or slow-drip response can't exhaust memory or stall
  the caller.
  """

  @behaviour MCP.OAuth.CIMD.Transport

  @impl MCP.OAuth.CIMD.Transport
  def fetch(%URI{} = uri, address, opts) do
    max_bytes = Keyword.fetch!(opts, :max_response_bytes)
    timeout = Keyword.fetch!(opts, :timeout_ms)
    pinned_url = %{uri | host: pin_host(address)} |> URI.to_string()
    acc_key = make_ref()
    Process.put(acc_key, [])

    result =
      Req.get(pinned_url,
        headers: [{"host", uri.host}, {"accept", "application/json"}],
        connect_options: [
          hostname: uri.host,
          transport_opts: [verify: :verify_peer],
          timeout: timeout
        ],
        receive_timeout: timeout,
        redirect: false,
        retry: false,
        into: fn {:data, data}, {req, resp} ->
          acc = [Process.get(acc_key, []) | [data]]

          if IO.iodata_length(acc) > max_bytes do
            {:halt, {req, resp}}
          else
            Process.put(acc_key, acc)
            {:cont, {req, resp}}
          end
        end
      )

    body = IO.iodata_to_binary(Process.get(acc_key, []))
    Process.delete(acc_key)

    cond do
      byte_size(body) > max_bytes ->
        {:error, :response_too_large}

      match?({:ok, _resp}, result) ->
        {:ok, resp} = result

        {:ok,
         %{
           status: resp.status,
           body: body,
           headers: resp |> Req.Response.get_header("location") |> location_header()
         }}

      true ->
        {:error, :fetch_failed}
    end
  end

  defp location_header([]), do: []
  defp location_header([value | _rest]), do: [{"location", value}]

  # IPv6 literals need bracketing when substituted into a URL authority.
  defp pin_host(address) when tuple_size(address) == 8 do
    "[" <> (address |> :inet.ntoa() |> to_string()) <> "]"
  end

  defp pin_host(address), do: address |> :inet.ntoa() |> to_string()
end
