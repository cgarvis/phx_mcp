defmodule MCP.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias MCP.TestSupport.TestServer

  @secret String.duplicate("k", 64)
  @base_url "https://mcp.test"
  @metadata_url "#{@base_url}/.well-known/oauth-protected-resource"
  @version_key "io.modelcontextprotocol/protocolVersion"
  @caps_key "io.modelcontextprotocol/clientCapabilities"
  @default_meta %{@version_key => "2026-07-28", @caps_key => %{"elicitation" => %{}}}

  @opts MCP.Plug.init(
          server: TestServer,
          auth:
            {MCP.Auth.Static,
             tokens: %{
               "tok-full" => {"alice", ["secret:read"]},
               "tok-none" => {"bob", []}
             },
             base_url: @base_url}
        )

  describe "auth" do
    test "missing bearer token yields 401 with resource metadata" do
      conn = dispatch_raw(request("tools/list"), token: nil)

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") ==
               [~s(Bearer resource_metadata="#{@metadata_url}")]

      assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
    end

    test "unknown token yields the same 401" do
      conn = dispatch_raw(request("tools/list"), token: "nope")
      assert conn.status == 401
    end

    test "base_url accepts an {m, f, a} resolved per request" do
      opts =
        MCP.Plug.init(
          server: TestServer,
          auth: {MCP.Auth.Static, base_url: {__MODULE__, :mfa_base_url, []}}
        )

      conn =
        conn(:post, "/", Jason.encode!(request("tools/list")))
        |> put_req_header("content-type", "application/json")
        |> MCP.Plug.call(opts)

      assert conn.status == 401

      assert get_resp_header(conn, "www-authenticate") ==
               [
                 ~s(Bearer resource_metadata="https://mfa.test/.well-known/oauth-protected-resource")
               ]
    end

    # Right in dev, wrong behind a TLS-terminating proxy, hence base_url.
    test "without a base_url the metadata pointer derives from the request" do
      opts = MCP.Plug.init(server: TestServer, auth: {MCP.Auth.Static, []})

      conn =
        conn(:post, "http://mcp.test/", Jason.encode!(request("tools/list")))
        |> put_req_header("content-type", "application/json")
        |> MCP.Plug.call(opts)

      assert get_resp_header(conn, "www-authenticate") ==
               [
                 ~s(Bearer resource_metadata="http://mcp.test/.well-known/oauth-protected-resource")
               ]
    end
  end

  describe "auth with allow_anonymous" do
    test "no authorization header is served with an empty context" do
      conn = anon_dispatch(request("tools/list"), token: nil)

      assert conn.status == 200

      names = Enum.map(Jason.decode!(conn.resp_body)["result"]["tools"], & &1["name"])
      assert "echo" in names
      refute "secret" in names
    end

    # The whole point: an ungated resource is readable with no credential at all.
    test "an ungated resource reads anonymously" do
      conn = anon_dispatch(request("resources/read", %{"uri" => "test://note"}), token: nil)

      assert conn.status == 200
      assert [%{"uri" => "test://note"}] = Jason.decode!(conn.resp_body)["result"]["contents"]
    end

    test "a scoped resource stays invisible to an anonymous caller" do
      conn = anon_dispatch(request("resources/read", %{"uri" => "test://secret"}), token: nil)

      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32602
    end

    # A presented credential is still a credential: bad ones fail closed.
    test "a bad token still 401s rather than falling back to anonymous" do
      conn = anon_dispatch(request("tools/list"), token: "nope")
      assert conn.status == 401
    end

    test "a valid token still carries its scopes" do
      conn = anon_dispatch(request("tools/list"), token: "tok-full")

      names = Enum.map(Jason.decode!(conn.resp_body)["result"]["tools"], & &1["name"])
      assert "secret" in names
    end
  end

  def mfa_base_url, do: "https://mfa.test"

  @anon_opts MCP.Plug.init(
               server: TestServer,
               auth: {MCP.Auth.Static, tokens: %{"tok-full" => {"alice", ["secret:read"]}}},
               allow_anonymous: true
             )

  defp anon_dispatch(body, opts) do
    token = Keyword.get(opts, :token)

    conn(:post, "/", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    end)
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(@anon_opts)
  end

  describe "transport shape" do
    test "malformed JSON is a -32700 with HTTP 400" do
      conn = dispatch_body("{not json")

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32700
    end

    test "a batch body is a -32600 with HTTP 400" do
      conn = dispatch_body("[]")

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32600
    end

    # MCP.Legacy supplies the version, so -32602 can no longer reach the plug.
    # The kernel contract it stands on is asserted in rpc_test.exs. Restore this
    # to a 400 when lib/mcp/legacy.ex is deleted.
    test "missing protocolVersion is filled in rather than rejected" do
      conn = dispatch(request("tools/list", %{}, meta: %{}))

      assert conn.status == 200
    end

    test "unsupported protocolVersion is a -32022 with HTTP 400" do
      conn = dispatch(request("tools/list", %{}, meta: %{@version_key => "2025-06-18"}))

      assert conn.status == 400
      error = Jason.decode!(conn.resp_body)["error"]
      assert error["code"] == -32022
      assert error["data"] == %{"supported" => ["2026-07-28"]}
    end

    test "unknown methods are -32601 with HTTP 404" do
      conn = dispatch(request("tools/nuke"))

      assert conn.status == 404
      assert %{"error" => %{"code" => -32601}} = json(conn)
    end

    test "non-POST is 405, other paths are 404" do
      assert MCP.Plug.call(conn(:get, "/"), @opts).status == 405
      assert MCP.Plug.call(conn(:post, "/deeper/path"), @opts).status == 404
    end

    test "a Mcp-Method mismatch is a -32020 with HTTP 400" do
      conn = dispatch(request("tools/list"), headers: [{"mcp-method", "tools/call"}])

      assert conn.status == 400
      error = json(conn)["error"]
      assert error["code"] == -32020

      assert error["message"] ==
               "Header mismatch: Mcp-Method header value 'tools/call' does not match body value 'tools/list'"
    end

    test "a Mcp-Name mismatch is a -32020 with HTTP 400" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hi"}}
      conn = dispatch(request("tools/call", params), headers: [{"mcp-name", "secret"}])

      assert conn.status == 400
      error = json(conn)["error"]
      assert error["code"] == -32020
      assert error["message"] =~ "Mcp-Name header value 'secret'"
    end

    # Only the first copy would be compared, while a proxy may route on another.
    test "a repeated Mcp-Method header is a -32020 even when one copy matches" do
      conn =
        conn(:post, "/", Jason.encode!(request("tools/list")))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer tok-full")
        |> prepend_req_headers([{"mcp-method", "tools/list"}, {"mcp-method", "tools/call"}])
        |> Map.replace!(:secret_key_base, @secret)
        |> MCP.Plug.call(@opts)

      assert conn.status == 400
      error = json(conn)["error"]
      assert error["code"] == -32020
      assert error["message"] =~ "'tools/list, tools/call'"
    end

    # Plug.Parsers only wraps under "_json" when that is the whole body.
    test "a body carrying its own _json member is not unwrapped" do
      body = Map.put(request("tools/list"), "_json", "decoy")

      conn =
        conn(:post, "/", "")
        |> put_req_header("authorization", "Bearer tok-full")
        |> Map.replace!(:body_params, body)
        |> Map.replace!(:secret_key_base, @secret)
        |> MCP.Plug.call(@opts)

      assert %{"result" => %{"resultType" => "complete"}} = json(conn)
    end

    test "matching routing headers pass through" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hi"}}

      conn =
        dispatch(request("tools/call", params),
          headers: [{"mcp-method", "tools/call"}, {"mcp-name", "echo"}]
        )

      assert %{"result" => %{"isError" => false}} = json(conn)
    end

    test "a browser Origin is refused unless allowed" do
      conn = dispatch(request("tools/list"), headers: [{"origin", "https://evil.test"}])

      assert conn.status == 403
      assert json(conn)["error"] == "origin_not_allowed"
    end

    test "an allowed Origin passes" do
      opts =
        MCP.Plug.init(
          server: TestServer,
          auth: {MCP.Auth.Static, tokens: %{"tok-full" => {"alice", ["secret:read"]}}},
          allowed_origins: ["https://app.test"]
        )

      conn =
        conn(:post, "/", Jason.encode!(request("tools/list")))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer tok-full")
        |> put_req_header("origin", "https://app.test")
        |> MCP.Plug.call(opts)

      assert %{"result" => _} = json(conn)
    end

    test "results carry the server identity in _meta" do
      meta = json(dispatch(request("tools/list")))["result"]["_meta"]

      assert meta["io.modelcontextprotocol/serverInfo"] ==
               %{"name" => "test-server", "version" => "9.9.9"}
    end
  end

  describe "server/discover" do
    test "discover returns the static capabilities document with cache metadata" do
      result = json(dispatch(request("server/discover")))["result"]

      assert result["serverInfo"] == %{"name" => "test-server", "version" => "9.9.9"}
      assert result["supportedVersions"] == ["2026-07-28"]
      assert result["capabilities"]["tools"] == %{"listChanged" => false}
      assert result["capabilities"]["resources"]["subscribe"] == false
      assert result["ttlMs"] == 1234
      assert result["cacheScope"] == "public"
    end
  end

  describe "prompts" do
    test "prompts/list carries argument payloads, filtered by scope" do
      result = json(dispatch(request("prompts/list")))["result"]

      assert result["resultType"] == "complete"
      assert result["ttlMs"] == 1234
      assert result["cacheScope"] == "public"

      assert Enum.map(result["prompts"], & &1["name"]) ==
               ["review", "secret-brief", "fail-prompt"]

      review = Enum.find(result["prompts"], &(&1["name"] == "review"))

      assert review == %{
               "name" => "review",
               "description" => "Ask for a review",
               "arguments" => [
                 %{"name" => "code", "description" => "The code to review", "required" => true},
                 %{"name" => "tone", "description" => "Review tone"}
               ]
             }

      secret = Enum.find(result["prompts"], &(&1["name"] == "secret-brief"))
      refute Map.has_key?(secret, "arguments")

      scoped = json(dispatch(request("prompts/list"), token: "tok-none"))["result"]
      assert Enum.map(scoped["prompts"], & &1["name"]) == ["review", "fail-prompt"]
    end

    test "prompts/get renders messages with validated arguments" do
      req = request("prompts/get", %{"name" => "review", "arguments" => %{"code" => "1+1"}})
      result = json(dispatch(req))["result"]

      assert result["resultType"] == "complete"
      assert result["description"] == "Ask for a review"

      assert result["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "I review in a kind tone."}
               },
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "Please review:\n1+1"}
               }
             ]
    end

    test "prompts/get passes raw spec-shaped message maps through" do
      result = json(dispatch(request("prompts/get", %{"name" => "secret-brief"})))["result"]

      assert result["messages"] == [
               %{
                 "role" => "user",
                 "content" => %{
                   "type" => "resource_link",
                   "uri" => "test://secret",
                   "name" => "secret-doc"
                 }
               }
             ]
    end

    test "unknown and out-of-scope prompts get the same -32602" do
      for req <- [
            dispatch(request("prompts/get", %{"name" => "nope"})),
            dispatch(request("prompts/get", %{"name" => "secret-brief"}), token: "tok-none")
          ] do
        error = json(req)["error"]
        assert error["code"] == -32_602
        assert error["message"] =~ "Unknown prompt"
      end
    end

    test "missing required argument is rejected before get runs" do
      req = request("prompts/get", %{"name" => "review", "arguments" => %{}})
      error = json(dispatch(req))["error"]

      assert error["code"] == -32_602
      assert error["message"] == "Invalid arguments for prompt: review"
      assert error["data"]["errors"] == ["code is required"]
    end

    test "undeclared arguments are rejected" do
      req =
        request("prompts/get", %{
          "name" => "review",
          "arguments" => %{"code" => "x", "bogus" => "y"}
        })

      error = json(dispatch(req))["error"]
      assert error["code"] == -32_602
      assert error["data"]["errors"] == [~s(unknown argument: "bogus")]
    end

    test "a failing prompt maps to -32603" do
      error = json(dispatch(request("prompts/get", %{"name" => "fail-prompt"})))["error"]

      assert error["code"] == -32_603
      assert error["message"] == "prompt backend down"
    end

    test "prompts/get without a name is invalid params" do
      error = json(dispatch(request("prompts/get", %{})))["error"]

      assert error["code"] == -32_602
      assert error["message"] == ~s(prompts/get requires a string "name")
    end
  end

  describe "resource templates" do
    test "resources/templates/list carries uriTemplate payloads, filtered by scope" do
      result = json(dispatch(request("resources/templates/list")))["result"]

      assert result["resultType"] == "complete"
      assert result["ttlMs"] == 1234
      assert result["cacheScope"] == "public"

      assert Enum.map(result["resourceTemplates"], & &1["uriTemplate"]) ==
               ["test://items/{id}", "test://secrets/{id}"]

      item = Enum.find(result["resourceTemplates"], &(&1["name"] == "item"))
      assert item["mimeType"] == "application/json"

      result = json(dispatch(request("resources/templates/list"), token: "tok-none"))["result"]
      assert Enum.map(result["resourceTemplates"], & &1["uriTemplate"]) == ["test://items/{id}"]
    end

    test "resources/read matches a template and passes the extracted params" do
      result = json(dispatch(request("resources/read", %{"uri" => "test://items/42"})))["result"]

      assert [%{"uri" => "test://items/42", "mimeType" => "application/json", "text" => text}] =
               result["contents"]

      assert Jason.decode!(text) == %{"id" => "42", "name" => "widget"}
    end

    test "scope gates template reads exactly like static resources" do
      ok = json(dispatch(request("resources/read", %{"uri" => "test://secrets/7"})))["result"]
      assert [%{"text" => "classified 7"}] = ok["contents"]

      error =
        json(
          dispatch(request("resources/read", %{"uri" => "test://secrets/7"}), token: "tok-none")
        )["error"]

      assert error["code"] == -32602
      assert error["message"] == "Resource not found"
    end

    test "an object-level not_found wears the same error as an unmatched URI" do
      error = json(dispatch(request("resources/read", %{"uri" => "test://items/999"})))["error"]

      assert error["code"] == -32602
      assert error["message"] == "Resource not found"
      assert error["data"] == %{"uri" => "test://items/999"}
    end

    test "a failing template read surfaces as an internal error" do
      error = json(dispatch(request("resources/read", %{"uri" => "test://items/boom"})))["error"]

      assert error["code"] == -32603
      assert error["message"] == "exploded"
    end

    test "a raise with a 404 plug_status wears the standard Resource not found" do
      error = json(dispatch(request("resources/read", %{"uri" => "test://items/gone"})))["error"]

      assert error["code"] == -32602
      assert error["message"] == "Resource not found"
      assert error["data"] == %{"uri" => "test://items/gone"}
    end

    test "raises without a 404 plug_status stay internal errors" do
      log =
        capture_log(fn ->
          error =
            json(dispatch(request("resources/read", %{"uri" => "test://items/raise"})))["error"]

          assert error["code"] == -32603
          assert error["message"] == "Internal error"
        end)

      assert log =~ "kaboom"
    end
  end

  describe "resources" do
    test "resources/list carries payloads and cache metadata, filtered by scope" do
      result = json(dispatch(request("resources/list")))["result"]

      assert result["resultType"] == "complete"
      assert result["ttlMs"] == 1234
      assert result["cacheScope"] == "public"

      note = Enum.find(result["resources"], &(&1["uri"] == "test://note"))
      assert note["name"] == "note"
      assert note["mimeType"] == "text/plain"

      uris = fn token ->
        json(dispatch(request("resources/list"), token: token))["result"]["resources"]
        |> Enum.map(& &1["uri"])
      end

      assert "test://secret" in uris.("tok-full")
      refute "test://secret" in uris.("tok-none")
    end

    test "resources/read returns text contents with cache metadata" do
      result = json(dispatch(request("resources/read", %{"uri" => "test://note"})))["result"]

      assert result ==
               %{
                 "resultType" => "complete",
                 "ttlMs" => 1234,
                 "cacheScope" => "public",
                 "contents" => [
                   %{"uri" => "test://note", "mimeType" => "text/plain", "text" => "a note"}
                 ]
               }
               |> with_server_meta()
    end

    test "a map read result is served as JSON text" do
      result = json(dispatch(request("resources/read", %{"uri" => "test://secret"})))["result"]

      assert [%{"mimeType" => "application/json", "text" => text}] = result["contents"]
      assert Jason.decode!(text) == %{"secret" => "s3kr3t"}
    end

    test "binary contents ride as base64 blobs" do
      result = json(dispatch(request("resources/read", %{"uri" => "test://blob"})))["result"]

      assert [%{"uri" => "test://blob", "blob" => blob}] = result["contents"]
      assert Base.decode64!(blob) == <<137, 80, 78, 71>>
    end

    test "unknown and out-of-scope URIs get the same Resource not found error" do
      unknown = json(dispatch(request("resources/read", %{"uri" => "test://nope"})))["error"]

      hidden =
        json(dispatch(request("resources/read", %{"uri" => "test://secret"}), token: "tok-none"))[
          "error"
        ]

      assert unknown["code"] == -32602
      assert unknown["message"] == "Resource not found"
      assert unknown["data"] == %{"uri" => "test://nope"}
      assert hidden["code"] == -32602
      assert hidden["message"] == "Resource not found"
    end

    test "resources/read requires a string uri" do
      error = json(dispatch(request("resources/read")))["error"]
      assert error["code"] == -32602
    end

    test "a failing read surfaces as an internal error with the message" do
      error = json(dispatch(request("resources/read", %{"uri" => "test://fail"})))["error"]

      assert error["code"] == -32603
      assert error["message"] == "backend down"
    end

    test "an exact resource wins over a template covering the same URI" do
      result =
        json(dispatch(request("resources/read", %{"uri" => "test://items/hidden"})))["result"]

      assert [%{"text" => text}] = result["contents"]
      assert Jason.decode!(text) == %{"hidden" => true}
    end

    # Falling through to the template would serve what the scope gate just denied.
    test "a gated exact resource does not fall through to its template" do
      response =
        json(
          dispatch(request("resources/read", %{"uri" => "test://items/hidden"}),
            token: "tok-none"
          )
        )

      assert response["error"]["message"] == "Resource not found"
      refute Map.has_key?(response, "result")
    end

    test "an unencodable read is an internal error, not a crash" do
      log =
        capture_log(fn ->
          error =
            json(dispatch(request("resources/read", %{"uri" => "test://unencodable"})))["error"]

          assert error == %{"code" => -32603, "message" => "Internal error"}
        end)

      assert log =~ "unencodable result"
    end
  end

  describe "tools/list" do
    test "lists tools with schemas and cache metadata" do
      result = json(dispatch(request("tools/list")))["result"]

      assert result["resultType"] == "complete"
      assert result["ttlMs"] == 1234
      assert result["cacheScope"] == "public"

      echo = Enum.find(result["tools"], &(&1["name"] == "echo"))
      assert echo["description"] == "Echo validated arguments"
      assert echo["inputSchema"]["required"] == ["text"]
    end

    test "outputSchema is published only by tools that declare one" do
      result = json(dispatch(request("tools/list")))["result"]

      assert Enum.find(result["tools"], &(&1["name"] == "drift"))["outputSchema"] == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{"count" => %{"type" => "integer"}},
               "required" => ["count"]
             }

      refute Map.has_key?(Enum.find(result["tools"], &(&1["name"] == "echo")), "outputSchema")
    end

    test "is filtered by the caller's scopes" do
      names = fn token ->
        json(dispatch(request("tools/list"), token: token))["result"]["tools"]
        |> Enum.map(& &1["name"])
      end

      assert "secret" in names.("tok-full")
      refute "secret" in names.("tok-none")
    end
  end

  describe "tools/call" do
    test "happy path returns structured content and a text block" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hi", "count" => 2}}
      result = json(dispatch(request("tools/call", params)))["result"]

      assert result["resultType"] == "complete"
      assert result["isError"] == false
      # level is absent from the request but declared with a default.
      assert result["structuredContent"] == %{
               "args" => %{"text" => "hi", "count" => 2, "level" => "low"}
             }

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert Jason.decode!(text) == result["structuredContent"]
    end

    test "argument validation failures are -32602 with itemized errors" do
      params = %{"name" => "echo", "arguments" => %{"count" => "x", "level" => "mid"}}
      error = json(dispatch(request("tools/call", params)))["error"]

      assert error["code"] == -32602
      assert "text is required" in error["data"]["errors"]
      assert "count must be a integer" in error["data"]["errors"]
      assert Enum.any?(error["data"]["errors"], &(&1 =~ "level must be one of"))
    end

    test "an out-of-scope tool is indistinguishable from an unknown one" do
      unknown = json(dispatch(request("tools/call", %{"name" => "no-such"})))["error"]

      hidden =
        json(dispatch(request("tools/call", %{"name" => "secret"}), token: "tok-none"))["error"]

      assert unknown["code"] == -32602
      assert hidden["code"] == -32602
      assert unknown["message"] == "Unknown tool: no-such"
      assert hidden["message"] == "Unknown tool: secret"
    end

    test "in-scope call succeeds" do
      result = json(dispatch(request("tools/call", %{"name" => "secret"})))["result"]
      assert result["structuredContent"] == %{"secret" => "s3kr3t"}
    end

    test "tool execution errors ride in the result with isError" do
      result = json(dispatch(request("tools/call", %{"name" => "fail"})))["result"]

      assert result["resultType"] == "complete"
      assert result["isError"] == true
      assert result["content"] == [%{"type" => "text", "text" => "boom: It broke"}]
      refute Map.has_key?(result, "structuredContent")
    end

    test "a result violating its outputSchema is refused, not sent" do
      log =
        capture_log(fn ->
          error = json(dispatch(request("tools/call", %{"name" => "drift"})))["error"]
          assert error["code"] == -32603
          assert error["message"] == "Internal error"
        end)

      assert log =~ "violating its outputSchema"
      assert log =~ "count must be a integer"
    end

    test "a raising tool is a -32603 internal error" do
      log =
        capture_log(fn ->
          error = json(dispatch(request("tools/call", %{"name" => "raise"})))["error"]
          assert error["code"] == -32603
          assert error["message"] == "Internal error"
        end)

      assert log =~ "kaboom"
    end

    # No outputSchema means nothing checked the shape before encoding.
    test "an unencodable result is an internal error, not a crash" do
      log =
        capture_log(fn ->
          error = json(dispatch(request("tools/call", %{"name" => "unencodable"})))["error"]
          assert error == %{"code" => -32603, "message" => "Internal error"}
        end)

      assert log =~ "unencodable result"
    end
  end

  describe "MRTR" do
    test "pause, then resume with input responses" do
      result = json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]

      assert result["resultType"] == "input_required"
      assert %{"answer" => %{"method" => "elicitation/create"}} = result["inputRequests"]
      handle = result["requestState"]
      assert is_binary(handle)

      responses = %{"answer" => %{"action" => "accept", "content" => %{"reply" => "yes"}}}
      params = %{"name" => "hold", "inputResponses" => responses, "requestState" => handle}
      resumed = json(dispatch(request("tools/call", params, id: 2)))["result"]

      assert resumed["resultType"] == "complete"

      # resume/3 sees the accepted content, not the envelope around it.
      assert resumed["structuredContent"] == %{
               "state" => %{"step" => 1},
               "responses" => %{"answer" => %{"reply" => "yes"}}
             }
    end

    test "declared fields become the restricted requestedSchema" do
      result = json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]

      assert result["inputRequests"]["answer"]["params"] == %{
               "mode" => "form",
               "message" => "Answer?",
               "requestedSchema" => %{
                 "type" => "object",
                 "properties" => %{"reply" => %{"type" => "string"}},
                 "required" => ["reply"]
               }
             }
    end

    test "a declined or cancelled response never reaches the tool" do
      for action <- ["decline", "cancel"] do
        handle =
          json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

        responses = %{"answer" => %{"action" => action}}
        params = %{"name" => "hold", "inputResponses" => responses, "requestState" => handle}
        resumed = json(dispatch(request("tools/call", params, id: 2)))["result"]

        assert resumed["isError"] == true
        assert [%{"text" => text}] = resumed["content"]
        assert text == "input_declined: Input was declined or cancelled: answer"
      end
    end

    # The handle seals what was asked, so silence is a decline rather than an
    # empty responses map handed to the tool.
    test "an unanswered request is a decline" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      params = %{"name" => "hold", "inputResponses" => %{}, "requestState" => handle}
      resumed = json(dispatch(request("tools/call", params, id: 2)))["result"]

      assert resumed["isError"] == true

      assert [%{"text" => "input_declined: Input was declined or cancelled: answer"}] =
               resumed["content"]
    end

    test "responses to names that were never requested are rejected" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      responses = %{
        "answer" => %{"action" => "accept", "content" => %{"reply" => "yes"}},
        "extra" => %{"action" => "accept", "content" => %{}}
      }

      params = %{"name" => "hold", "inputResponses" => responses, "requestState" => handle}
      error = json(dispatch(request("tools/call", params, id: 2)))["error"]

      assert error["code"] == -32602
      assert error["message"] == "Unrequested input responses: extra"
    end

    test "a non-object inputResponses is a -32602" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      params = %{"name" => "hold", "inputResponses" => ["nope"], "requestState" => handle}
      error = json(dispatch(request("tools/call", params, id: 2)))["error"]

      assert error["code"] == -32602
      assert error["message"] == "inputResponses must be an object"
    end

    test "a tampered requestState is a protocol error" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      params = %{"name" => "hold", "requestState" => handle <> "x"}
      error = json(dispatch(request("tools/call", params, id: 2)))["error"]

      assert error["code"] == -32602
      assert error["message"] =~ "invalid requestState"
    end

    test "another principal cannot resume the call" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      params = %{"name" => "hold", "requestState" => handle}
      error = json(dispatch(request("tools/call", params, id: 2), token: "tok-none"))["error"]

      assert error["code"] == -32602
      assert error["message"] =~ "does not belong"
    end

    test "a requestState against a non-MRTR tool is rejected" do
      handle =
        json(dispatch(request("tools/call", %{"name" => "hold"})))["result"]["requestState"]

      params = %{"name" => "echo", "arguments" => %{"text" => "hi"}, "requestState" => handle}
      error = json(dispatch(request("tools/call", params, id: 2)))["error"]

      assert error["code"] == -32602
    end

    test "eliciting a client that never declared elicitation is a -32021 with HTTP 400" do
      conn =
        dispatch(
          request("tools/call", %{"name" => "hold"}, meta: %{@version_key => "2026-07-28"})
        )

      assert conn.status == 400
      error = json(conn)["error"]

      assert error["code"] == -32021
      assert error["message"] =~ "elicitation"
      assert error["data"] == %{"requiredCapabilities" => %{"elicitation" => %{}}}
    end
  end

  defp request(method, params \\ %{}, opts \\ []) do
    meta = Keyword.get(opts, :meta, @default_meta)

    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp dispatch(body, opts \\ []), do: dispatch_raw(body, opts)

  defp dispatch_raw(body, opts) do
    token = Keyword.get(opts, :token, "tok-full")
    body = if is_binary(body), do: body, else: Jason.encode!(body)

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    end)
    |> then(fn conn ->
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
    end)
    |> Map.replace!(:secret_key_base, @secret)
    |> MCP.Plug.call(@opts)
  end

  defp dispatch_body(raw), do: dispatch_raw(raw, [])

  defp json(conn) do
    assert conn.status in [200, 400, 403, 404]
    Jason.decode!(conn.resp_body)
  end

  defp with_server_meta(result) do
    Map.put(result, "_meta", %{
      "io.modelcontextprotocol/serverInfo" => %{"name" => "test-server", "version" => "9.9.9"}
    })
  end
end
