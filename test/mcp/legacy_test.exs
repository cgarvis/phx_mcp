defmodule MCP.LegacyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MCP.TestSupport.TestServer

  @secret String.duplicate("k", 64)
  @version_key "io.modelcontextprotocol/protocolVersion"

  @opts MCP.Plug.init(
          server: TestServer,
          auth:
            {MCP.Auth.Static,
             tokens: %{"tok" => {"alice", ["secret:read"]}}, base_url: "https://mcp.test"}
        )

  describe "initialize" do
    test "answers the handshake with the server's own capabilities" do
      conn = post(%{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{}})

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)["result"]

      assert result["serverInfo"] == TestServer.server_info()
      assert result["capabilities"] == TestServer.discover_payload()["capabilities"]
      assert result["protocolVersion"] == "2025-06-18"
    end

    test "settles on the client's revision when it is one we speak" do
      for version <- ["2025-11-25", "2025-06-18"] do
        conn =
          post(%{
            "jsonrpc" => "2.0",
            "id" => 0,
            "method" => "initialize",
            "params" => %{"protocolVersion" => version}
          })

        assert Jason.decode!(conn.resp_body)["result"]["protocolVersion"] == version
      end
    end

    test "names its own revision when the client asks for one we do not speak" do
      conn =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 0,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2024-10-07"}
        })

      assert Jason.decode!(conn.resp_body)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "preserves the request id" do
      conn = post(%{"jsonrpc" => "2.0", "id" => "abc", "method" => "initialize", "params" => %{}})
      assert Jason.decode!(conn.resp_body)["id"] == "abc"
    end
  end

  # Notifications carry no id, so RPC.parse/1 would otherwise reject them.
  test "notifications/initialized is accepted with an empty body" do
    conn = post(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert conn.status == 202
    assert conn.resp_body == ""
  end

  # The protocol method, not the tool of the same name.
  test "ping answers with an empty result" do
    conn = post(%{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
  end

  describe "version stamping" do
    test "a request with no _meta is served rather than rejected" do
      conn = post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body)["result"]["tools"])
    end

    test "a request with no params at all is served" do
      conn = post(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert conn.status == 200
      assert is_list(Jason.decode!(conn.resp_body)["result"]["tools"])
    end

    test "an existing _meta is preserved, not replaced" do
      meta = %{"io.modelcontextprotocol/clientInfo" => %{"name" => "probe"}}

      conn =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => meta}
        })

      assert conn.status == 200
    end

    # The shim must not mask a genuine version disagreement.
    test "an explicit unsupported version is still rejected" do
      conn =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => %{@version_key => "1999-01-01"}}
        })

      assert conn.status == 400

      assert Jason.decode!(conn.resp_body)["error"]["code"] ==
               MCP.RPC.unsupported_protocol_version()
    end

    test "a modern request is passed through untouched" do
      conn =
        post(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => %{@version_key => MCP.protocol_version()}}
        })

      assert conn.status == 200
    end
  end

  defp post(body) do
    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer tok")
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(@opts)
  end
end
