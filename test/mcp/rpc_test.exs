defmodule MCP.RPCTest do
  use ExUnit.Case, async: true

  alias MCP.RPC
  alias MCP.RPC.Request

  @version_key "io.modelcontextprotocol/protocolVersion"

  describe "parse/1" do
    test "parses a valid request and extracts _meta" do
      body = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "ping", "_meta" => %{@version_key => "2026-07-28"}}
      }

      assert {:ok, %Request{id: 7, method: "tools/call", params: params, meta: meta}} =
               RPC.parse(body)

      assert params["name"] == "ping"
      assert meta[@version_key] == "2026-07-28"
    end

    test "defaults absent params to an empty map" do
      assert {:ok, %Request{params: %{}, meta: %{}}} =
               RPC.parse(%{"jsonrpc" => "2.0", "id" => "a", "method" => "tools/list"})
    end

    test "rejects a wrong jsonrpc version" do
      assert {:error, {-32600, _, nil}, 1} =
               RPC.parse(%{"jsonrpc" => "1.0", "id" => 1, "method" => "m"})
    end

    test "rejects a missing or null id" do
      assert {:error, {-32600, message, nil}, nil} =
               RPC.parse(%{"jsonrpc" => "2.0", "method" => "m"})

      assert message =~ "id"
    end

    test "rejects a non-string method" do
      assert {:error, {-32600, _, nil}, 1} = RPC.parse(%{"jsonrpc" => "2.0", "id" => 1})
    end

    test "rejects non-object params" do
      assert {:error, {-32600, _, nil}, 1} =
               RPC.parse(%{"jsonrpc" => "2.0", "id" => 1, "method" => "m", "params" => [1]})
    end

    test "rejects batches and non-object bodies" do
      assert {:error, {-32600, _, nil}, nil} = RPC.parse([%{"jsonrpc" => "2.0"}])
      assert {:error, {-32600, _, nil}, nil} = RPC.parse("nope")
    end
  end

  describe "negotiate_version/1" do
    test "accepts the supported version" do
      assert :ok = RPC.negotiate_version(request_with_version("2026-07-28"))
    end

    test "missing version is invalid params" do
      assert {:error, :missing, {-32602, message, nil}} =
               RPC.negotiate_version(%Request{id: 1, method: "m"})

      assert message =~ @version_key
    end

    # Interpolating a bare term into the message can itself raise.
    test "a non-string version is unsupported, not a crash" do
      for version <- [123, %{"v" => 1}, ["2026-07-28"]] do
        assert {:error, :unsupported, {-32022, message, data}} =
                 RPC.negotiate_version(request_with_version(version))

        assert message =~ "Unsupported protocol version"
        assert data == %{"supported" => ["2026-07-28"]}
      end
    end

    test "unsupported version lists supported versions in data" do
      assert {:error, :unsupported, {-32022, message, data}} =
               RPC.negotiate_version(request_with_version("2025-06-18"))

      assert message =~ "2025-06-18"
      assert data == %{"supported" => ["2026-07-28"]}
    end
  end

  describe "responses" do
    test "result_response round-trips through encode" do
      response = RPC.result_response(3, %{"resultType" => "complete"})

      assert response |> RPC.encode!() |> Jason.decode!() == %{
               "jsonrpc" => "2.0",
               "id" => 3,
               "result" => %{"resultType" => "complete"}
             }
    end

    test "error_response omits data when nil and includes it otherwise" do
      assert RPC.error_response(1, {-32601, "nope", nil})["error"] == %{
               "code" => -32601,
               "message" => "nope"
             }

      assert RPC.error_response(1, {-32022, "v", %{"supported" => ["x"]}})["error"]["data"] ==
               %{"supported" => ["x"]}
    end

    test "put_server_info preserves existing _meta keys" do
      result = %{"resultType" => "complete", "_meta" => %{"traceparent" => "00-abc"}}
      info = %{"name" => "s", "version" => "1"}

      meta = RPC.put_server_info(result, info)["_meta"]
      assert meta["traceparent"] == "00-abc"
      assert meta["io.modelcontextprotocol/serverInfo"] == info
    end
  end

  defp request_with_version(version) do
    %Request{id: 1, method: "m", meta: %{@version_key => version}}
  end
end
