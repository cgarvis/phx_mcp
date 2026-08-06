defmodule MCP.RPC do
  @moduledoc """
  JSON-RPC 2.0 envelope handling: parse, encode, standard error codes, `_meta`
  extraction, and protocol-version negotiation.
  """

  alias MCP.RPC.Request

  @meta_protocol_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_info "io.modelcontextprotocol/clientInfo"
  @meta_client_capabilities "io.modelcontextprotocol/clientCapabilities"
  @meta_server_info "io.modelcontextprotocol/serverInfo"

  # JSON-RPC 2.0 standard codes.
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603
  # MCP spec codes (reserved range -32020..-32099).
  @header_mismatch -32020
  @missing_required_client_capability -32021
  @unsupported_protocol_version -32022

  def parse_error, do: @parse_error
  def invalid_request, do: @invalid_request
  def method_not_found, do: @method_not_found
  def invalid_params, do: @invalid_params
  def internal_error, do: @internal_error
  def header_mismatch, do: @header_mismatch
  def missing_required_client_capability, do: @missing_required_client_capability
  def unsupported_protocol_version, do: @unsupported_protocol_version

  def meta_client_info_key, do: @meta_client_info
  def meta_client_capabilities_key, do: @meta_client_capabilities

  @doc """
  Parses a decoded JSON body into a `MCP.RPC.Request`.

  Returns `{:error, error, id}` with a best-effort id so the error response can
  still be correlated. Batch requests are not part of MCP and are rejected.
  """
  def parse(body) when is_map(body) do
    id = if valid_id?(body["id"]), do: body["id"]
    params = body["params"]

    cond do
      body["jsonrpc"] != "2.0" ->
        {:error, {@invalid_request, "Invalid Request: jsonrpc must be \"2.0\"", nil}, id}

      is_nil(id) ->
        {:error, {@invalid_request, "Invalid Request: id must be a string or integer", nil}, nil}

      not is_binary(body["method"]) ->
        {:error, {@invalid_request, "Invalid Request: method must be a string", nil}, id}

      not (is_nil(params) or is_map(params)) ->
        {:error, {@invalid_request, "Invalid Request: params must be an object", nil}, id}

      true ->
        params = params || %{}
        meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}
        {:ok, %Request{id: id, method: body["method"], params: params, meta: meta}}
    end
  end

  def parse(_body), do: {:error, {@invalid_request, "Invalid Request", nil}, nil}

  @doc """
  Checks the per-request protocol version carried in `_meta`.

  Missing version is a malformed request (`-32602`, HTTP 400 at the transport);
  an unrecognized version gets `-32022` with the supported list in `data`.
  """
  def negotiate_version(%Request{meta: meta}) do
    case meta[@meta_protocol_version] do
      version when version in [nil, ""] ->
        {:error, :missing,
         {@invalid_params, "Missing required _meta field: #{@meta_protocol_version}", nil}}

      version when is_binary(version) ->
        if version in MCP.supported_versions() do
          :ok
        else
          {:error, :unsupported, unsupported_version(version)}
        end

      # Still unusable, but inspect it: interpolating a bare term can raise.
      other ->
        {:error, :unsupported, unsupported_version(inspect(other))}
    end
  end

  defp unsupported_version(version) do
    {@unsupported_protocol_version, "Unsupported protocol version: #{version}",
     %{"supported" => MCP.supported_versions()}}
  end

  def result_response(id, result) when is_map(result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  @doc "Stamps the server identity into the result's `_meta`, preserving existing keys."
  def put_server_info(result, server_info) when is_map(result) do
    meta = Map.get(result, "_meta", %{})
    Map.put(result, "_meta", Map.put_new(meta, @meta_server_info, server_info))
  end

  def error_response(id, {code, message, data}) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  def encode!(response), do: Jason.encode!(response)

  defp valid_id?(id), do: is_binary(id) or is_integer(id)
end
