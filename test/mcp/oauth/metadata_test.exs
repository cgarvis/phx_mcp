defmodule MCP.OAuth.MetadataTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.Metadata

  test "builds an RFC 8414 document from the issuer, no OIDC fields" do
    doc = Metadata.document("https://auth.example.com", scopes: ["mcp:read", "mcp:write"])

    assert doc["issuer"] == "https://auth.example.com"
    assert doc["authorization_endpoint"] == "https://auth.example.com/authorize"
    assert doc["token_endpoint"] == "https://auth.example.com/token"
    assert doc["introspection_endpoint"] == "https://auth.example.com/introspect"
    assert doc["revocation_endpoint"] == "https://auth.example.com/revoke"
    assert doc["scopes_supported"] == ["mcp:read", "mcp:write"]
    assert doc["response_types_supported"] == ["code"]

    assert doc["grant_types_supported"] == [
             "authorization_code",
             "refresh_token",
             "client_credentials"
           ]

    assert doc["code_challenge_methods_supported"] == ["S256"]

    assert doc["token_endpoint_auth_methods_supported"] == [
             "none",
             "client_secret_basic",
             "client_secret_post"
           ]

    refute Map.has_key?(doc, "jwks_uri")
    refute Map.has_key?(doc, "userinfo_endpoint")
    refute Map.has_key?(doc, "id_token_signing_alg_values_supported")
  end

  test "trims a trailing slash off the issuer and honors endpoint overrides" do
    doc =
      Metadata.document("https://auth.example.com/",
        token_endpoint: "https://auth.example.com/oauth/token"
      )

    assert doc["issuer"] == "https://auth.example.com"
    assert doc["token_endpoint"] == "https://auth.example.com/oauth/token"
    assert doc["authorization_endpoint"] == "https://auth.example.com/authorize"
  end

  test "defaults scopes_supported to an empty list" do
    assert Metadata.document("https://auth.example.com")["scopes_supported"] == []
  end

  describe "registration_endpoint" do
    test "is absent unless the host says it mounted one" do
      refute Map.has_key?(Metadata.document("https://auth.example.com"), "registration_endpoint")
    end

    test "is advertised verbatim when passed" do
      doc =
        Metadata.document("https://auth.example.com",
          registration_endpoint: "https://auth.example.com/oauth/register"
        )

      assert doc["registration_endpoint"] == "https://auth.example.com/oauth/register"
    end
  end

  describe "client_id_metadata_document_supported" do
    test "is absent unless the host resolves CIMD client_ids" do
      doc = Metadata.document("https://auth.example.com")

      refute Map.has_key?(doc, "client_id_metadata_document_supported")
    end

    test "is absent when the host passes false, not advertised as false" do
      doc = Metadata.document("https://auth.example.com", cimd_supported: false)

      refute Map.has_key?(doc, "client_id_metadata_document_supported")
    end

    test "is advertised when the host passes true" do
      doc = Metadata.document("https://auth.example.com", cimd_supported: true)

      assert doc["client_id_metadata_document_supported"] == true
    end
  end
end
