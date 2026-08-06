defmodule MCP.URLTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "a configured base wins over the request and loses its trailing slash" do
    conn = conn(:get, "http://internal.test:4000/")

    assert MCP.URL.join(conn, "https://mcp.test/", "/mcp") == "https://mcp.test/mcp"
  end

  # The pointer and the identifier must agree, so both trim the default port.
  test "a derived origin omits the scheme's default port" do
    assert MCP.URL.join(conn(:get, "https://mcp.test/"), nil, "/mcp") == "https://mcp.test/mcp"
    assert MCP.URL.join(conn(:get, "http://mcp.test/"), nil, "/mcp") == "http://mcp.test/mcp"

    assert MCP.URL.join(conn(:get, "http://mcp.test:4000/"), nil, "/mcp") ==
             "http://mcp.test:4000/mcp"
  end

  test "metadata_url appends the path RFC 9728 fixes" do
    assert MCP.URL.metadata_url(conn(:get, "/"), "https://mcp.test") ==
             "https://mcp.test/.well-known/oauth-protected-resource"
  end

  # RFC 9728 §3.1: the resource's path goes after the well-known segment.
  test "metadata_url inserts the resource path" do
    conn = conn(:get, "/")

    assert MCP.URL.metadata_url(conn, "https://mcp.test", "/mcp") ==
             "https://mcp.test/.well-known/oauth-protected-resource/mcp"

    assert MCP.URL.metadata_url(conn, "https://mcp.test", "/") ==
             "https://mcp.test/.well-known/oauth-protected-resource"
  end
end
