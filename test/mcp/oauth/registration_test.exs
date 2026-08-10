defmodule MCP.OAuth.RegistrationTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.{Client, Registration}

  @scopes ["profile:read", "biomarkers:read", "records:read:full"]

  describe "the shape a self-registered client gets" do
    test "is public, PKCE-enforced, and code-grant only, whatever was asked for" do
      assert {:ok, %Client{} = client} =
               build(%{
                 "client_name" => "Claude",
                 "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
                 "token_endpoint_auth_method" => "client_secret_post",
                 "grant_types" => ["authorization_code"]
               })

      assert client.secret_hash == nil
      assert client.confidential? == false
      assert client.pkce_required? == true
      assert client.grant_types == ["authorization_code", "refresh_token"]
      assert client.dynamically_registered? == true
      assert client.name == "Claude"
      assert client.redirect_uris == ["https://claude.ai/api/mcp/auth_callback"]
      assert String.starts_with?(client.id, "client_")
    end

    test "refuses client_credentials rather than quietly dropping it" do
      assert {:error, {"invalid_client_metadata", description}} =
               build(%{
                 "client_name" => "Batch job",
                 "redirect_uris" => ["https://client.test/cb"],
                 "grant_types" => ["authorization_code", "client_credentials"]
               })

      assert description =~ "client_credentials"
    end

    test "refuses a grant type it does not implement" do
      assert {:error, {"invalid_client_metadata", _}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "grant_types" => ["implicit"]
               })
    end

    test "refuses a response_type other than code" do
      assert {:error, {"invalid_client_metadata", _}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "response_types" => ["code", "token"]
               })
    end
  end

  describe "redirect_uris" do
    test "accepts https and loopback http" do
      assert {:ok, client} =
               build(%{
                 "redirect_uris" => [
                   "https://client.test/cb",
                   "http://127.0.0.1:33418/callback",
                   "http://localhost:8080/cb"
                 ]
               })

      assert length(client.redirect_uris) == 3
    end

    test "stores them verbatim, since authorize matches by exact string" do
      uri = "https://client.test/cb?tenant=7"
      assert {:ok, %Client{redirect_uris: [^uri]}} = build(%{"redirect_uris" => [uri]})
    end

    test "refuses plain http off loopback" do
      assert {:error, {"invalid_redirect_uri", _}} =
               build(%{"redirect_uris" => ["http://client.test/cb"]})
    end

    test "refuses a non-http scheme" do
      for uri <- ["myapp://cb", "javascript:alert(1)", "data:text/html,x", "ftp://host/cb"] do
        assert {:error, {"invalid_redirect_uri", _}} = build(%{"redirect_uris" => [uri]})
      end
    end

    test "refuses wildcards, fragments, userinfo, and hostless URLs" do
      for uri <- [
            "https://*.client.test/cb",
            "https://client.test/cb#frag",
            "https://user:pw@client.test/cb",
            "https:///cb"
          ] do
        assert {:error, {"invalid_redirect_uri", _}} = build(%{"redirect_uris" => [uri]})
      end
    end

    test "requires a non-empty array" do
      for metadata <- [%{}, %{"redirect_uris" => []}, %{"redirect_uris" => "https://a.test/cb"}] do
        assert {:error, {"invalid_redirect_uri", _}} = build(metadata)
      end
    end

    test "caps the list length and each URI's length" do
      many = for n <- 1..11, do: "https://client.test/cb#{n}"
      assert {:error, {"invalid_redirect_uri", _}} = build(%{"redirect_uris" => many})

      long = "https://client.test/" <> String.duplicate("a", 256)
      assert {:error, {"invalid_redirect_uri", _}} = build(%{"redirect_uris" => [long]})
    end
  end

  describe "scope" do
    test "is intersected with what the AS can issue" do
      assert {:ok, %Client{scopes: scopes}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "scope" => "profile:read records:read:full admin:everything"
               })

      assert scopes == ["profile:read", "records:read:full"]
    end

    test "defaults to the full declared set when absent" do
      assert {:ok, %Client{scopes: @scopes}} =
               build(%{"redirect_uris" => ["https://client.test/cb"]})
    end

    test "an entirely unsupported scope is an error, not an empty grant" do
      assert {:error, {"invalid_client_metadata", _}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "scope" => "admin:everything"
               })
    end
  end

  describe "display metadata" do
    test "keeps https client_uri and logo_uri" do
      assert {:ok, client} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "client_uri" => "https://claude.ai",
                 "logo_uri" => "https://claude.ai/logo.png"
               })

      assert client.client_uri == "https://claude.ai"
      assert client.logo_uri == "https://claude.ai/logo.png"
    end

    test "refuses a non-https display URL" do
      assert {:error, {"invalid_client_metadata", _}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "logo_uri" => "http://claude.ai/logo.png"
               })
    end

    test "names a client that did not name itself" do
      assert {:ok, %Client{name: "Unnamed client"}} =
               build(%{"redirect_uris" => ["https://client.test/cb"], "client_name" => "  "})
    end

    test "caps client_name" do
      assert {:error, {"invalid_client_metadata", _}} =
               build(%{
                 "redirect_uris" => ["https://client.test/cb"],
                 "client_name" => String.duplicate("n", 129)
               })
    end
  end

  describe "response/2" do
    test "echoes the registered shape and never a secret" do
      {:ok, client} =
        build(%{"client_name" => "Claude", "redirect_uris" => ["https://client.test/cb"]})

      body = Registration.response(client, 1_754_000_000)

      assert body["client_id"] == client.id
      assert body["client_id_issued_at"] == 1_754_000_000
      assert body["client_name"] == "Claude"
      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      assert body["response_types"] == ["code"]
      assert body["scope"] == Enum.join(@scopes, " ")
      refute Map.has_key?(body, "client_secret")
    end
  end

  test "a non-object body is invalid metadata" do
    assert {:error, {"invalid_client_metadata", _}} = Registration.build("not json")
  end

  defp build(metadata), do: Registration.build(metadata, scopes: @scopes)
end
