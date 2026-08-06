defmodule MCP.TelemetryTest do
  # Handlers are global, so this cannot run beside other MCP tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias MCP.TestSupport.TestServer

  @secret String.duplicate("k", 64)
  @version_key "io.modelcontextprotocol/protocolVersion"
  @caps_key "io.modelcontextprotocol/clientCapabilities"

  @opts MCP.Plug.init(
          server: TestServer,
          auth: {MCP.Auth.Static, tokens: %{"tok-full" => {"alice", ["secret:read"]}}}
        )

  setup do
    handler = {__MODULE__, System.unique_integer()}
    :telemetry.attach_many(handler, MCP.Telemetry.events(), &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def forward(event, measurements, metadata, pid) do
    send(pid, {:event, event, measurements, metadata})
  end

  test "events/0 lists both spans" do
    assert MCP.Telemetry.events() == [
             [:mcp, :request, :start],
             [:mcp, :request, :stop],
             [:mcp, :request, :exception],
             [:mcp, :handler, :start],
             [:mcp, :handler, :stop],
             [:mcp, :handler, :exception]
           ]
  end

  test "a request span carries the method, principal, and HTTP status" do
    dispatch("tools/list")

    assert_received {:event, [:mcp, :request, :start], %{system_time: _},
                     %{method: "tools/list", name: nil, principal: "alice"}}

    assert_received {:event, [:mcp, :request, :stop], %{duration: duration},
                     %{method: "tools/list", principal: "alice", status: 200, error_code: nil}}

    assert is_integer(duration)
  end

  test "a protocol error stop carries the status and the JSON-RPC code" do
    dispatch("tools/nuke")

    assert_received {:event, [:mcp, :request, :stop], _measurements,
                     %{status: 404, error_code: -32601}}
  end

  test "a tool call spans the handler under its name" do
    dispatch("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})

    assert_received {:event, [:mcp, :handler, :start], %{system_time: _},
                     %{kind: :tool, name: "echo", principal: "alice"}}

    assert_received {:event, [:mcp, :handler, :stop], %{duration: _},
                     %{kind: :tool, name: "echo", outcome: :ok}}
  end

  test "a paused tool stops with outcome input_required" do
    dispatch("tools/call", %{"name" => "hold"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :tool, name: "hold", outcome: :input_required}}
  end

  test "a resource read spans as :resource, a template read as :resource_template" do
    dispatch("resources/read", %{"uri" => "test://note"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :resource, name: "test://note", outcome: :ok}}

    dispatch("resources/read", %{"uri" => "test://items/42"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :resource_template, name: "test://items/{id}", outcome: :ok}}
  end

  test "a prompt get spans as :prompt" do
    dispatch("prompts/get", %{"name" => "review", "arguments" => %{"code" => "1 + 1"}})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :prompt, name: "review", outcome: :ok}}
  end

  test "a raising handler emits an exception event, not a stop" do
    capture_log(fn -> dispatch("tools/call", %{"name" => "raise"}) end)

    assert_received {:event, [:mcp, :handler, :exception], %{duration: _},
                     %{kind: :tool, name: "raise", kind_of_error: :error, reason: reason}}

    assert %RuntimeError{message: "kaboom"} = reason
    refute_received {:event, [:mcp, :handler, :stop], _measurements, %{name: "raise"}}
  end

  test "a 404-status raise is a stop with outcome not_found" do
    dispatch("resources/read", %{"uri" => "test://items/gone"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :resource_template, outcome: :not_found}}

    refute_received {:event, [:mcp, :handler, :exception], _measurements, _metadata}
  end

  # A raise that escapes the handler layer becomes a 500; without this the span
  # would open and never close.
  test "a raise escaping the request emits an exception event, not a stop" do
    opts =
      MCP.Plug.init(
        server: MCP.TestSupport.BoomServer,
        auth: {MCP.Auth.Static, tokens: %{"tok-full" => {"alice", []}}}
      )

    assert_raise RuntimeError, "boom", fn ->
      conn(:post, "/", Jason.encode!(request("server/discover")))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer tok-full")
      |> Map.replace!(:secret_key_base, @secret)
      |> MCP.Plug.call(opts)
    end

    assert_received {:event, [:mcp, :request, :exception], %{duration: _},
                     %{
                       method: "server/discover",
                       kind: :error,
                       reason: reason,
                       stacktrace: [_ | _]
                     }}

    assert %RuntimeError{message: "boom"} = reason
    refute_received {:event, [:mcp, :request, :stop], _measurements, _metadata}
  end

  test "requests rejected before auth emit no span" do
    conn(:post, "/", Jason.encode!(request("tools/list")))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> MCP.Plug.call(@opts)

    refute_received {:event, [:mcp, :request, :start], _measurements, _metadata}
  end

  defp dispatch(method, params \\ %{}) do
    conn(:post, "/", Jason.encode!(request(method, params)))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer tok-full")
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(@opts)
  end

  defp request(method, params \\ %{}) do
    meta = %{@version_key => "2026-07-28", @caps_key => %{"elicitation" => %{}}}

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end
end
