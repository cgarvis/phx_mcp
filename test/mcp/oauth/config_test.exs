defmodule MCP.OAuth.ConfigTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.Config

  setup do
    on_exit(fn -> Application.delete_env(:mcp_oauth_config_test, MCP.OAuth) end)
  end

  test "reads a plain value from config :otp_app, MCP.OAuth, key: value" do
    Application.put_env(:mcp_oauth_config_test, MCP.OAuth, issuer: "https://issuer.test")

    assert Config.fetch(:mcp_oauth_config_test, :issuer) == "https://issuer.test"
  end

  test "resolves one level of {m, f, a}, matching the shape config itself may hold" do
    Application.put_env(:mcp_oauth_config_test, MCP.OAuth, scopes: {__MODULE__, :scope_names, []})

    assert Config.fetch(:mcp_oauth_config_test, :scopes) == ["mcp:read", "mcp:write"]
  end

  test "an unset key fetches as nil, not an error" do
    Application.put_env(:mcp_oauth_config_test, MCP.OAuth, issuer: "https://issuer.test")

    assert Config.fetch(:mcp_oauth_config_test, :default_resource) == nil
  end

  test "an unconfigured otp_app fetches as nil, not an error" do
    assert Config.fetch(:mcp_oauth_config_test_unconfigured, :issuer) == nil
  end

  test "reads fresh on every call, not once" do
    Application.put_env(:mcp_oauth_config_test, MCP.OAuth, issuer: "https://before.test")
    assert Config.fetch(:mcp_oauth_config_test, :issuer) == "https://before.test"

    Application.put_env(:mcp_oauth_config_test, MCP.OAuth, issuer: "https://after.test")
    assert Config.fetch(:mcp_oauth_config_test, :issuer) == "https://after.test"
  end

  def scope_names, do: ["mcp:read", "mcp:write"]
end
