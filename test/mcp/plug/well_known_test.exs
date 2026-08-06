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

  def base_url, do: "https://mfa.test"
end
