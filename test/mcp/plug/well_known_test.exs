defmodule MCP.Plug.WellKnownTest do
  use ExUnit.Case, async: true

  import Plug.Test

  @opts MCP.Plug.WellKnown.init(
          resource: "/mcp",
          base_url: "https://mcp.test",
          authorization_servers: ["https://auth.test"]
        )

  test "serves the RFC 9728 document built from base_url and the mount path" do
    conn = conn(:get, "/") |> MCP.Plug.WellKnown.call(@opts)

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "resource" => "https://mcp.test/mcp",
             "authorization_servers" => ["https://auth.test"]
           }
  end

  test "base_url may be an {m, f, a} resolved per request" do
    opts = MCP.Plug.WellKnown.init(resource: "/mcp", base_url: {__MODULE__, :base_url, []})
    conn = conn(:get, "/") |> MCP.Plug.WellKnown.call(opts)

    assert Jason.decode!(conn.resp_body)["resource"] == "https://mfa.test/mcp"
  end

  test "without a base_url the resource derives from the request" do
    opts = MCP.Plug.WellKnown.init(resource: "/mcp")
    conn = conn(:get, "https://mcp.test/") |> MCP.Plug.WellKnown.call(opts)

    assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.test/mcp"
  end

  test "authorization_servers fall back to otp_app config" do
    Application.put_env(:mcp_well_known_test, MCP.Plug.WellKnown,
      authorization_servers: ["https://config.test"]
    )

    on_exit(fn -> Application.delete_env(:mcp_well_known_test, MCP.Plug.WellKnown) end)

    opts = MCP.Plug.WellKnown.init(resource: "/mcp", otp_app: :mcp_well_known_test)
    conn = conn(:get, "/") |> MCP.Plug.WellKnown.call(opts)

    assert Jason.decode!(conn.resp_body)["authorization_servers"] == ["https://config.test"]
  end

  test "an unconfigured host advertises no authorization servers" do
    opts = MCP.Plug.WellKnown.init(resource: "/mcp")
    conn = conn(:get, "/") |> MCP.Plug.WellKnown.call(opts)

    assert Jason.decode!(conn.resp_body)["authorization_servers"] == []
  end

  test "the document is GET-only" do
    conn = conn(:post, "/") |> MCP.Plug.WellKnown.call(@opts)

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end

  # RFC 9728 §3.1: the 401 challenge points at the path-inserted URL.
  test "serves the resource path appended to the well-known mount" do
    conn = conn(:get, "/mcp") |> MCP.Plug.WellKnown.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.test/mcp"
  end

  test "the path-inserted URL is GET-only too" do
    conn = conn(:post, "/mcp") |> MCP.Plug.WellKnown.call(@opts)

    assert conn.status == 405
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
  end

  test "a path that is not the resource's is a 404" do
    assert conn(:get, "/nested") |> MCP.Plug.WellKnown.call(@opts) |> Map.fetch!(:status) == 404

    assert conn(:get, "/mcp/deeper") |> MCP.Plug.WellKnown.call(@opts) |> Map.fetch!(:status) ==
             404

    assert conn(:post, "/nested") |> MCP.Plug.WellKnown.call(@opts) |> Map.fetch!(:status) == 404
  end

  test "a resource must be mounted" do
    assert_raise KeyError, fn -> MCP.Plug.WellKnown.init([]) end
  end

  # The regression this guards: authorization_servers is read inside
  # document/2, called from call/2, not baked into the map init/1 returns.
  # A router's `forward` calls init/1 once, at compile time; if the value
  # were resolved there, config.exs would work but a runtime.exs override
  # would silently do nothing in production. Proving it means changing the
  # env *after* init and calling the already-initialized opts, not just
  # setting it beforehand as the "fall back to otp_app config" test above
  # does.
  test "authorization_servers set after init is still served, not baked in at init time" do
    Application.put_env(:mcp_well_known_runtime_test, MCP.Plug.WellKnown,
      authorization_servers: ["https://before.test"]
    )

    on_exit(fn -> Application.delete_env(:mcp_well_known_runtime_test, MCP.Plug.WellKnown) end)

    opts = MCP.Plug.WellKnown.init(resource: "/mcp", otp_app: :mcp_well_known_runtime_test)

    assert conn(:get, "/")
           |> MCP.Plug.WellKnown.call(opts)
           |> resp_json()
           |> Map.fetch!("authorization_servers") ==
             ["https://before.test"]

    Application.put_env(:mcp_well_known_runtime_test, MCP.Plug.WellKnown,
      authorization_servers: ["https://after.test"]
    )

    assert conn(:get, "/")
           |> MCP.Plug.WellKnown.call(opts)
           |> resp_json()
           |> Map.fetch!("authorization_servers") ==
             ["https://after.test"]
  end

  describe "mount: :endpoint" do
    @endpoint_opts MCP.Plug.WellKnown.init(
                     resource: "/mcp",
                     base_url: "https://mcp.test",
                     mount: :endpoint
                   )

    test "serves the document at the bare well-known prefix" do
      conn =
        conn(:get, "/.well-known/oauth-protected-resource")
        |> MCP.Plug.WellKnown.call(@endpoint_opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.test/mcp"
    end

    test "serves the document at the §3.1 path-inserted sub-path" do
      conn =
        conn(:get, "/.well-known/oauth-protected-resource/mcp")
        |> MCP.Plug.WellKnown.call(@endpoint_opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["resource"] == "https://mcp.test/mcp"
    end

    test "a request under the well-known prefix but not this resource is a 404" do
      conn =
        conn(:get, "/.well-known/oauth-protected-resource/other")
        |> MCP.Plug.WellKnown.call(@endpoint_opts)

      assert conn.status == 404
    end

    # The behavior a forwarded plug cannot have: unrelated requests (the
    # app's real routes) reach an endpoint plug too, and must fall through
    # untouched rather than being claimed or 404'd, so the rest of the
    # endpoint pipeline and the router still run.
    test "an unrelated request passes through untouched, not halted, not 404'd" do
      original = conn(:get, "/mcp")
      conn = MCP.Plug.WellKnown.call(original, @endpoint_opts)

      refute conn.halted
      assert conn.status == nil
      assert conn == original
    end

    test "the app's root path passes through rather than being claimed as the bare mount" do
      original = conn(:get, "/")
      conn = MCP.Plug.WellKnown.call(original, @endpoint_opts)

      refute conn.halted
      assert conn == original
    end

    test "an unrelated POST also passes through" do
      original = conn(:post, "/some/other/route")
      conn = MCP.Plug.WellKnown.call(original, @endpoint_opts)

      refute conn.halted
      assert conn == original
    end
  end

  test "an invalid :mount is a clear error, not a silent fall-through to :forward" do
    assert_raise ArgumentError, ~r/:mount must be :forward or :endpoint/, fn ->
      MCP.Plug.WellKnown.init(resource: "/mcp", mount: :bogus)
    end
  end

  def base_url, do: "https://mfa.test"

  defp resp_json(conn), do: Jason.decode!(conn.resp_body)
end
