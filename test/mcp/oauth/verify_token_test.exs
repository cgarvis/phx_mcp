defmodule MCP.OAuthTest.VerifyTokenTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth
  alias MCP.OAuth.Store.Memory
  alias MCP.OAuth.TestFixtures
  alias MCP.OAuth.{Secret, Token}

  setup do
    start_supervised!(Memory)
    :ok
  end

  defp mint_access_token(client, sub, scope, audience) do
    plain = "token-" <> Secret.new()

    :ok =
      Memory.put_token(%Token{
        access_hash: Secret.hash(plain),
        client_id: client.id,
        sub: sub,
        scope: scope,
        audience: audience,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    plain
  end

  test "a token whose audience contains the requested resource is accepted" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain =
      mint_access_token(client, "user-1", "mcp:read", ["https://mcp.test/a", "https://mcp.test/b"])

    assert {:ok, %{sub: "user-1", scopes: ["mcp:read"]}} =
             OAuth.verify_token(Memory, plain, "https://mcp.test/a")
  end

  test "a token whose audience does not contain the requested resource is rejected" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = mint_access_token(client, "user-1", "mcp:read", ["https://mcp.test/a"])

    assert {:error, :invalid_token} = OAuth.verify_token(Memory, plain, "https://mcp.test/other")
  end

  test "a nil resource skips the audience check" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = mint_access_token(client, "user-1", "mcp:read", ["https://mcp.test/a"])

    assert {:ok, %{}} = OAuth.verify_token(Memory, plain, nil)
  end

  test "an unknown token is rejected" do
    assert {:error, :invalid_token} = OAuth.verify_token(Memory, "not-a-real-token", nil)
  end

  test "an expired token is rejected" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = "expired-" <> Secret.new()

    :ok =
      Memory.put_token(%Token{
        access_hash: Secret.hash(plain),
        client_id: client.id,
        sub: "user-1",
        scope: "mcp:read",
        audience: [],
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    assert {:error, :invalid_token} = OAuth.verify_token(Memory, plain, nil)
  end

  test "a revoked token is rejected" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = mint_access_token(client, "user-1", "mcp:read", [])
    :ok = Memory.revoke_token(Secret.hash(plain))

    assert {:error, :invalid_token} = OAuth.verify_token(Memory, plain, nil)
  end

  test "introspect mirrors verify_token: active for a live token, inactive otherwise" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = mint_access_token(client, "user-1", "mcp:read", ["https://mcp.test/a"])

    assert %{active: true, sub: "user-1", client_id: client_id} =
             OAuth.introspect(Memory, %{"token" => plain})

    assert client_id == client.id
    assert %{active: false} == OAuth.introspect(Memory, %{"token" => "garbage"})
  end

  test "revoke is idempotent and revoking makes introspect report inactive" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain = mint_access_token(client, "user-1", "mcp:read", [])

    assert :ok = OAuth.revoke(Memory, %{"token" => plain})
    assert :ok = OAuth.revoke(Memory, %{"token" => plain})
    assert %{active: false} = OAuth.introspect(Memory, %{"token" => plain})
  end
end
