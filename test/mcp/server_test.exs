defmodule MCP.ServerTest do
  use ExUnit.Case, async: true

  describe "validate_cache_scope!/1" do
    test "accepts the two scopes the spec defines" do
      assert MCP.Server.validate_cache_scope!("public") == "public"
      assert MCP.Server.validate_cache_scope!("private") == "private"
    end

    test "rejects anything else at compile time" do
      assert_raise ArgumentError, ~r/cache_scope/, fn ->
        MCP.Server.validate_cache_scope!("client")
      end
    end
  end

  describe "advertised capabilities" do
    test "a server declares only the features it actually registered" do
      capabilities = MCP.TestSupport.TestServer.discover_payload()["capabilities"]

      assert capabilities == %{
               "tools" => %{"listChanged" => false},
               "resources" => %{"listChanged" => false, "subscribe" => false},
               "prompts" => %{"listChanged" => false}
             }
    end

    test "a server with nothing registered advertises nothing" do
      assert MCP.TestSupport.BareServer.discover_payload()["capabilities"] == %{}
    end
  end

  describe "server metadata" do
    test "cache_meta/0 carries both required CacheableResult fields" do
      assert MCP.TestSupport.TestServer.cache_meta() ==
               %{"ttlMs" => 1234, "cacheScope" => "public"}
    end

    test "server_info/0 is the name and version given to `use`" do
      assert MCP.TestSupport.TestServer.server_info() ==
               %{"name" => "test-server", "version" => "9.9.9"}
    end
  end
end
