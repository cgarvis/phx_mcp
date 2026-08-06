defmodule MCP.OAuthTest.AuthorizeTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth
  alias MCP.OAuth.Store.Memory
  alias MCP.OAuth.TestFixtures

  setup do
    start_supervised!(Memory)
    :ok
  end

  test "exact redirect_uri match issues a code" do
    {client, _secret} =
      TestFixtures.confidential_client(%{redirect_uris: ["https://client.test/cb"]})

    Memory.put_client(client)

    assert {:ok, %{redirect_uri: "https://client.test/cb", query: %{code: code, state: "xyz"}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => client.id,
                 "redirect_uri" => "https://client.test/cb",
                 "state" => "xyz"
               },
               "user-1"
             )

    assert is_binary(code)
  end

  test "a redirect_uri that does not exactly match a registered one is rejected without a redirect" do
    {client, _secret} =
      TestFixtures.confidential_client(%{redirect_uris: ["https://client.test/cb"]})

    Memory.put_client(client)

    # Trailing slash, query string, different path -- none are the registered URI.
    for bad_uri <- [
          "https://client.test/cb/",
          "https://client.test/cb?x=1",
          "https://evil.test/cb"
        ] do
      assert {:error, {:invalid_redirect, :mismatch}} =
               OAuth.authorize(
                 Memory,
                 %{
                   "response_type" => "code",
                   "client_id" => client.id,
                   "redirect_uri" => bad_uri
                 },
                 "user-1"
               )
    end
  end

  test "an unknown client_id is rejected without a redirect" do
    assert {:error, {:invalid_redirect, :unknown_client}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => "no-such-client",
                 "redirect_uri" => "https://client.test/cb"
               },
               "user-1"
             )
  end

  test "a missing redirect_uri is rejected without a redirect" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    assert {:error, {:invalid_redirect, :missing_redirect_uri}} =
             OAuth.authorize(
               Memory,
               %{"response_type" => "code", "client_id" => client.id},
               "user-1"
             )
  end

  test "PKCE is required for a public client -- missing code_challenge fails" do
    client = TestFixtures.public_client()
    Memory.put_client(client)

    assert {:error, {:redirect, redirect_uri, %{error: "invalid_request"}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => client.id,
                 "redirect_uri" => hd(client.redirect_uris)
               },
               "user-1"
             )

    assert redirect_uri == hd(client.redirect_uris)
  end

  test "PKCE is required for a public client -- a non-S256 method fails" do
    client = TestFixtures.public_client()
    Memory.put_client(client)

    assert {:error, {:redirect, _uri, %{error: "invalid_request"}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => client.id,
                 "redirect_uri" => hd(client.redirect_uris),
                 "code_challenge" => "abc",
                 "code_challenge_method" => "plain"
               },
               "user-1"
             )
  end

  test "PKCE is not required for a confidential client that does not opt into it" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    assert {:ok, %{query: %{code: code}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => client.id,
                 "redirect_uri" => hd(client.redirect_uris)
               },
               "user-1"
             )

    assert is_binary(code)
  end

  test "an unsupported response_type is a redirect error" do
    {client, _secret} = TestFixtures.confidential_client()
    Memory.put_client(client)

    assert {:error, {:redirect, _uri, %{error: "unsupported_response_type"}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "token",
                 "client_id" => client.id,
                 "redirect_uri" => hd(client.redirect_uris)
               },
               "user-1"
             )
  end

  test "a scope outside the client's registered scopes is a redirect error" do
    {client, _secret} = TestFixtures.confidential_client(%{scopes: ["mcp:read"]})
    Memory.put_client(client)

    assert {:error, {:redirect, _uri, %{error: "invalid_scope"}}} =
             OAuth.authorize(
               Memory,
               %{
                 "response_type" => "code",
                 "client_id" => client.id,
                 "redirect_uri" => hd(client.redirect_uris),
                 "scope" => "mcp:read mcp:admin"
               },
               "user-1"
             )
  end
end
