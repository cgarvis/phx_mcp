defmodule MCP.OAuthTest.TokenTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth
  alias MCP.OAuth.Store.Memory
  alias MCP.OAuth.TestFixtures
  alias MCP.OAuth.{Code, Secret}

  setup do
    start_supervised!(Memory)
    :ok
  end

  test "a full authorization_code exchange, with PKCE, returns an access + refresh token" do
    client = TestFixtures.public_client(%{scopes: ["mcp:read", "mcp:write"]})
    Memory.put_client(client)

    verifier = "verifier-" <> Secret.new()
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "scope" => "mcp:read",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "resource" => "https://mcp.test/server"
        },
        "user-1"
      )

    assert {:ok, response} =
             OAuth.token(Memory, %{
               "grant_type" => "authorization_code",
               "client_id" => client.id,
               "code" => code,
               "redirect_uri" => hd(client.redirect_uris),
               "code_verifier" => verifier
             })

    assert response.token_type == "bearer"
    assert response.scope == "mcp:read"
    assert is_binary(response.access_token)
    assert is_binary(response.refresh_token)
    assert response.expires_in > 0

    assert {:ok, %{sub: "user-1", client_id: client_id, scopes: ["mcp:read"]}} =
             OAuth.verify_token(Memory, response.access_token, "https://mcp.test/server")

    assert client_id == client.id
  end

  test "a wrong code_verifier fails the exchange" do
    client = TestFixtures.public_client()
    Memory.put_client(client)

    verifier = "verifier-" <> Secret.new()
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris),
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        },
        "user-1"
      )

    assert {:error, %{error: "invalid_grant"}} =
             OAuth.token(Memory, %{
               "grant_type" => "authorization_code",
               "client_id" => client.id,
               "code" => code,
               "redirect_uri" => hd(client.redirect_uris),
               "code_verifier" => "not-the-right-verifier"
             })
  end

  test "an authorization code is single-use -- the second exchange fails" do
    {client, secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => hd(client.redirect_uris)
        },
        "user-1"
      )

    params = %{
      "grant_type" => "authorization_code",
      "client_id" => client.id,
      "client_secret" => secret,
      "code" => code,
      "redirect_uri" => hd(client.redirect_uris)
    }

    assert {:ok, _response} = OAuth.token(Memory, params)

    assert {:error, %{error: "invalid_grant"}} = OAuth.token(Memory, params)
  end

  test "an expired authorization code is rejected" do
    {client, secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    plain_code = "expired-code-" <> Secret.new()

    Memory.put_code(%Code{
      code_hash: Secret.hash(plain_code),
      client_id: client.id,
      redirect_uri: hd(client.redirect_uris),
      scope: "mcp:read",
      sub: "user-1",
      expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    })

    assert {:error, %{error: "invalid_grant", status: 400}} =
             OAuth.token(Memory, %{
               "grant_type" => "authorization_code",
               "client_id" => client.id,
               "client_secret" => secret,
               "code" => plain_code,
               "redirect_uri" => hd(client.redirect_uris)
             })
  end

  test "a redirect_uri that does not match the one used at authorize time fails" do
    {client, secret} =
      TestFixtures.confidential_client(%{
        redirect_uris: ["https://client.test/cb", "https://client.test/cb2"]
      })

    Memory.put_client(client)

    {:ok, %{query: %{code: code}}} =
      OAuth.authorize(
        Memory,
        %{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => "https://client.test/cb"
        },
        "user-1"
      )

    assert {:error, %{error: "invalid_grant"}} =
             OAuth.token(Memory, %{
               "grant_type" => "authorization_code",
               "client_id" => client.id,
               "client_secret" => secret,
               "code" => code,
               "redirect_uri" => "https://client.test/cb2"
             })
  end

  test "an unsupported grant_type is rejected" do
    assert {:error, %{error: "unsupported_grant_type"}} =
             OAuth.token(Memory, %{"grant_type" => "password"})
  end
end
