defmodule MCP.OAuthTest.ClientCredentialsTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth
  alias MCP.OAuth.Store.Memory
  alias MCP.OAuth.TestFixtures

  setup do
    start_supervised!(Memory)
    :ok
  end

  test "a confidential client with the right secret gets a client-only access token, no refresh token" do
    {client, secret} = TestFixtures.confidential_client(%{scopes: ["mcp:admin"]})
    Memory.put_client(client)

    assert {:ok, response} =
             OAuth.token(Memory, %{
               "grant_type" => "client_credentials",
               "client_id" => client.id,
               "client_secret" => secret,
               "resource" => "https://mcp.test/server"
             })

    assert is_binary(response.access_token)
    assert response.refresh_token == nil
    assert response.scope == "mcp:admin"

    assert {:ok, %{sub: nil, principal: principal}} =
             OAuth.verify_token(Memory, response.access_token, "https://mcp.test/server")

    assert principal == "client:" <> client.id
  end

  test "the wrong secret is rejected" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    assert {:error, %{error: "invalid_client", status: 401}} =
             OAuth.token(Memory, %{
               "grant_type" => "client_credentials",
               "client_id" => client.id,
               "client_secret" => "definitely-not-the-secret"
             })
  end

  test "a public client cannot use client_credentials" do
    client = TestFixtures.public_client()
    Memory.put_client(client)

    assert {:error, %{error: "unauthorized_client"}} =
             OAuth.token(Memory, %{"grant_type" => "client_credentials", "client_id" => client.id})
  end

  test "a missing client_secret is rejected" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    assert {:error, %{error: "invalid_request"}} =
             OAuth.token(Memory, %{"grant_type" => "client_credentials", "client_id" => client.id})
  end
end
