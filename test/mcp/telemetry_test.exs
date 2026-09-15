defmodule MCP.TelemetryTest do
  # Handlers are global, so this cannot run beside other MCP tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias MCP.TestSupport.TestServer

  @secret String.duplicate("k", 64)
  @version_key "io.modelcontextprotocol/protocolVersion"
  @caps_key "io.modelcontextprotocol/clientCapabilities"
  @client_key "io.modelcontextprotocol/clientInfo"
  @client %{"name" => "fixture-client", "version" => "1.2.3"}

  defmodule CodeTemplate do
    @moduledoc false

    use MCP.ResourceTemplate,
      uri_template: "telemetry://codes/{code}",
      name: "code",
      scopes: ["secret:read"]

    @impl true
    def description, do: "A code by id"

    @impl true
    def read(_uri, %__MODULE__{code: code}, _ctx), do: {:ok, %{code: code}}

    @impl true
    def complete("code", _value, _ctx), do: {:ok, ["apob"]}
  end

  defmodule CompletionServer do
    @moduledoc false

    use MCP.Server,
      name: "completion-server",
      version: "1.0.0",
      resource_templates: [MCP.TelemetryTest.CodeTemplate]
  end

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

  test "a request span carries the caller's scopes, client info, and declared version" do
    dispatch("tools/list")

    assert_received {:event, [:mcp, :request, :start], _measurements,
                     %{
                       granted_scopes: ["secret:read"],
                       client: %{"name" => "fixture-client", "version" => "1.2.3"},
                       protocol_version: "2026-07-28"
                     }}

    assert_received {:event, [:mcp, :request, :stop], _measurements,
                     %{granted_scopes: ["secret:read"], protocol_version: "2026-07-28"}}
  end

  test "a request span carries the user-agent and vendor-client headers" do
    [vendor_header | _rest] = MCP.Telemetry.vendor_client_headers()

    dispatch("tools/list", %{},
      headers: [{"user-agent", "fixture-cli/2.1.0 (cli)"}, {vendor_header, "fixture-surface"}]
    )

    assert_received {:event, [:mcp, :request, :start], _measurements,
                     %{user_agent: "fixture-cli/2.1.0 (cli)", vendor_client: "fixture-surface"}}
  end

  test "every header in vendor_client_headers/0 populates :vendor_client" do
    for vendor_header <- MCP.Telemetry.vendor_client_headers() do
      dispatch("tools/list", %{}, headers: [{vendor_header, "fixture-surface"}])

      assert_received {:event, [:mcp, :request, :start], _measurements,
                       %{vendor_client: "fixture-surface"}},
                      "#{vendor_header} is listed but did not reach the span"
    end
  end

  # A host reading the span cannot tell a header we do not check from one the
  # caller never sent, so an unlisted name must not quietly become nil-adjacent
  # evidence of anything.
  test "a vendor header the kernel does not list is ignored" do
    refute "x-unlisted-vendor" in MCP.Telemetry.vendor_client_headers()

    dispatch("tools/list", %{}, headers: [{"x-unlisted-vendor", "fixture-surface"}])

    assert_received {:event, [:mcp, :request, :start], _measurements, %{vendor_client: nil}}
  end

  test "absent client info and absent client headers report as nil, not as missing keys" do
    dispatch("tools/list", %{}, client: nil)

    assert_received {:event, [:mcp, :request, :start], _measurements, metadata}

    assert %{client: nil, user_agent: nil, vendor_client: nil} = metadata
    assert Map.has_key?(metadata, :client)
    assert Map.has_key?(metadata, :user_agent)
    assert Map.has_key?(metadata, :vendor_client)
  end

  # MCP.Legacy stamps this server's own revision onto a request that declares
  # none, so the span reports what dispatch actually ran under rather than the
  # nothing the client sent. The field is never nil on this path.
  test "a request declaring no protocol version reports the stamped revision" do
    dispatch("tools/list", %{}, protocol_version: nil)

    assert_received {:event, [:mcp, :request, :start], _measurements,
                     %{protocol_version: "2026-07-28"}}
  end

  # The version is read before negotiation rejects it: the requests worth
  # counting are exactly the ones declaring something this server refuses.
  test "a request declaring an unsupported version reports the version it declared" do
    dispatch("tools/list", %{}, protocol_version: "1999-01-01")

    assert_received {:event, [:mcp, :request, :start], _measurements,
                     %{protocol_version: "1999-01-01"}}

    assert_received {:event, [:mcp, :request, :stop], _measurements,
                     %{status: 400, protocol_version: "1999-01-01"}}
  end

  test "a handler span carries the entry's description and required scopes" do
    dispatch("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})

    assert_received {:event, [:mcp, :handler, :start], _measurements,
                     %{
                       kind: :tool,
                       name: "echo",
                       description: "Echo validated arguments",
                       required_scopes: []
                     }}

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{name: "echo", description: "Echo validated arguments", required_scopes: []}}
  end

  test "a scope-gated tool reports the scopes it requires, not the caller's" do
    dispatch("tools/call", %{"name" => "secret"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{
                       name: "secret",
                       description: "Visible only with secret:read",
                       required_scopes: ["secret:read"],
                       outcome: :ok
                     }}
  end

  test "resource, template, and prompt handler spans carry their descriptions" do
    dispatch("resources/read", %{"uri" => "test://note"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :resource, description: "A plain-text note", required_scopes: []}}

    dispatch("resources/read", %{"uri" => "test://items/42"})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{
                       kind: :resource_template,
                       description: "An item by id",
                       required_scopes: []
                     }}

    dispatch("prompts/get", %{"name" => "review", "arguments" => %{"code" => "1 + 1"}})

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :prompt, description: "Ask for a review", required_scopes: []}}
  end

  test "a handler span repeats the per-request client, version, and session id" do
    dispatch("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}},
      headers: [{"mcp-session-id", "sess-from-client"}]
    )

    assert_received {:event, [:mcp, :handler, :start], _measurements,
                     %{
                       client: %{"name" => "fixture-client"},
                       protocol_version: "2026-07-28",
                       session_id: "sess-from-client"
                     }}

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{protocol_version: "2026-07-28", session_id: "sess-from-client"}}
  end

  test "a handler span reports a nil client when the request declared none" do
    dispatch("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}}, client: nil)

    assert_received {:event, [:mcp, :handler, :start], _measurements, metadata}

    assert %{client: nil} = metadata
    assert Map.has_key?(metadata, :client)
  end

  test "a client-supplied session id wins over the instance id" do
    dispatch("tools/list", %{}, headers: [{"mcp-session-id", "sess-from-client"}])

    assert_received {:event, [:mcp, :request, :start], _measurements,
                     %{session_id: "sess-from-client"}}

    refute MCP.Telemetry.instance_id() == "sess-from-client"
  end

  # An empty header is not a supplied id; falling through keeps the field
  # always present rather than emitting "".
  test "an empty session-id header falls through to the instance id" do
    dispatch("tools/list", %{}, headers: [{"mcp-session-id", ""}])

    instance_id = MCP.Telemetry.instance_id()

    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: ^instance_id}}
  end

  test "a request carrying no session id falls back to the instance id" do
    dispatch("tools/list")

    instance_id = MCP.Telemetry.instance_id()

    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: ^instance_id}}
  end

  test "the instance id is the same for every request on a node" do
    dispatch("tools/list")
    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: first}}

    dispatch("prompts/list")
    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: second}}

    assert is_binary(first)
    assert first == second
    assert first == MCP.Telemetry.instance_id()
  end

  # Completion is a handler span like any other, and the moduledoc promises
  # :description and :required_scopes on every one of them. A consumer pattern-matching
  # those keys that raises here is detached by :telemetry permanently, taking
  # all MCP telemetry on the node with it.
  test "a completion span carries the entry's description and required scopes" do
    completion_opts =
      MCP.Plug.init(
        server: CompletionServer,
        auth: {MCP.Auth.Static, tokens: %{"tok-full" => {"alice", ["secret:read"]}}}
      )

    params = %{
      "ref" => %{"type" => "ref/resource", "uri" => "telemetry://codes/{code}"},
      "argument" => %{"name" => "code", "value" => "ap"}
    }

    conn(:post, "/", Jason.encode!(request("completion/complete", params)))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer tok-full")
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(completion_opts)

    assert_received {:event, [:mcp, :handler, :start], _measurements,
                     %{
                       kind: :completion,
                       name: "telemetry://codes/{code}",
                       description: "A code by id",
                       required_scopes: ["secret:read"]
                     }}

    assert_received {:event, [:mcp, :handler, :stop], _measurements,
                     %{kind: :completion, description: "A code by id", outcome: :ok}}
  end

  # A host is invited to use :session_id as a metric tag, so an authenticated
  # caller must not be able to choose an unbounded or unprintable one.
  test "an oversized or non-printable session id falls through to the instance id" do
    instance_id = MCP.Telemetry.instance_id()

    dispatch("tools/list", %{}, headers: [{"mcp-session-id", String.duplicate("x", 129)}])
    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: ^instance_id}}

    dispatch("tools/list", %{}, headers: [{"mcp-session-id", "has space"}])
    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: ^instance_id}}
  end

  test "a session id at the length limit is still honoured" do
    at_limit = String.duplicate("x", 128)

    dispatch("tools/list", %{}, headers: [{"mcp-session-id", at_limit}])

    assert_received {:event, [:mcp, :request, :start], _measurements, %{session_id: ^at_limit}}
  end

  # A bare string under a key every type signature promises is a map means the
  # first consumer writing meta.client["name"] raises, and :telemetry detaches
  # a raising handler -- one crafted request would silence every MCP span on
  # the node until restart.
  test "a clientInfo that is not an object reports as nil rather than reaching the span" do
    for malformed <- ["i-am-not-a-map", 42, ["a", "list"]] do
      dispatch("tools/list", %{}, client: malformed)

      assert_received {:event, [:mcp, :request, :start], _measurements, metadata}

      assert metadata.client == nil,
             "#{inspect(malformed)} reached the span as #{inspect(metadata.client)}"

      assert metadata.client["name"] == nil
    end
  end

  test "a malformed clientInfo is dropped on handler spans too" do
    dispatch("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}},
      client: "i-am-not-a-map"
    )

    assert_received {:event, [:mcp, :handler, :start], _measurements, metadata}
    assert metadata.client == nil
  end

  # The whole point of the qualified names: a host attaching all six events
  # with one attach_many/4 cannot reach for metadata[:scopes] and silently
  # blend a caller's granted list with an entry's required one.
  test "neither span carries a bare :scopes key" do
    dispatch("tools/call", %{"name" => "secret"})

    assert_received {:event, [:mcp, :request, :start], _measurements, request_meta}
    assert_received {:event, [:mcp, :handler, :start], _measurements, handler_meta}

    refute Map.has_key?(request_meta, :scopes)
    refute Map.has_key?(handler_meta, :scopes)

    assert request_meta.granted_scopes == ["secret:read"]
    assert handler_meta.required_scopes == ["secret:read"]
    refute Map.has_key?(request_meta, :required_scopes)
    refute Map.has_key?(handler_meta, :granted_scopes)
  end

  defp dispatch(method, params \\ %{}, opts \\ []) do
    conn(:post, "/", Jason.encode!(request(method, params, opts)))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer tok-full")
    |> put_req_headers(Keyword.get(opts, :headers, []))
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(@opts)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_req_header(acc, name, value)
    end)
  end

  # `:protocol_version` and `:client` accept an explicit nil to drop the key,
  # which is the only way to exercise a request that omits it.
  defp request(method, params \\ %{}, opts \\ []) do
    meta =
      %{@caps_key => %{"elicitation" => %{}}}
      |> put_unless_nil(@version_key, Keyword.get(opts, :protocol_version, "2026-07-28"))
      |> put_unless_nil(@client_key, Keyword.get(opts, :client, @client))

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
