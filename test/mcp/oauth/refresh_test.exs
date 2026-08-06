defmodule MCP.OAuthTest.RefreshTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth
  alias MCP.OAuth.Store.Memory
  alias MCP.OAuth.TestFixtures

  setup do
    start_supervised!(Memory)
    :ok
  end

  defp issue_initial_token(client, secret) do
    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "resource" => "https://mcp.test/server"
        },
        "user-1"
      )

    OAuth.token(Memory, %{
      "grant_type" => "authorization_code",
      "client_id" => client.id,
      "client_secret" => secret,
      "code" => code,
      "redirect_uri" => hd(client.redirect_uris)
    })
  end

  test "rotation issues a new access + refresh token and revokes the old access token" do
    {client, secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    {:ok, first} = issue_initial_token(client, secret)

    assert {:ok, %{}} = OAuth.verify_token(Memory, first.access_token, nil)

    assert {:ok, second} =
             OAuth.token(Memory, %{
               "grant_type" => "refresh_token",
               "client_id" => client.id,
               "client_secret" => secret,
               "refresh_token" => first.refresh_token
             })

    assert second.access_token != first.access_token
    assert second.refresh_token != first.refresh_token

    # The old access token no longer verifies -- rotation revoked it.
    assert {:error, :invalid_token} = OAuth.verify_token(Memory, first.access_token, nil)
    # The new one does, and carries the audience forward.
    assert {:ok, %{}} = OAuth.verify_token(Memory, second.access_token, "https://mcp.test/server")
  end

  test "the old refresh token cannot be replayed after rotation" do
    {client, secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    {:ok, first} = issue_initial_token(client, secret)

    refresh_params = %{
      "grant_type" => "refresh_token",
      "client_id" => client.id,
      "client_secret" => secret,
      "refresh_token" => first.refresh_token
    }

    assert {:ok, _second} = OAuth.token(Memory, refresh_params)
    assert {:error, %{error: "invalid_grant"}} = OAuth.token(Memory, refresh_params)
  end

  test "scope can be narrowed but not expanded on refresh" do
    {client, secret} = TestFixtures.confidential_client(%{scopes: ["mcp:read", "mcp:write"]})
    Memory.put_client(client)

    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "scope" => "mcp:read mcp:write"
        },
        "user-1"
      )

    {:ok, first} =
      OAuth.token(Memory, %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "client_secret" => secret,
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris)
      })

    assert {:ok, %{scope: "mcp:read"}} =
             OAuth.token(Memory, %{
               "grant_type" => "refresh_token",
               "client_id" => client.id,
               "client_secret" => secret,
               "refresh_token" => first.refresh_token,
               "scope" => "mcp:read"
             })
  end

  test "a refresh token issued to another client is rejected" do
    {client, secret} = TestFixtures.confidential_client()
    {other_client, other_secret} = TestFixtures.confidential_client()
    Memory.put_client(client)
    Memory.put_client(other_client)

    {:ok, first} = issue_initial_token(client, secret)

    assert {:error, %{error: "invalid_grant"}} =
             OAuth.token(Memory, %{
               "grant_type" => "refresh_token",
               "client_id" => other_client.id,
               "client_secret" => other_secret,
               "refresh_token" => first.refresh_token
             })
  end
end
