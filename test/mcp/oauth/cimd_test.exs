defmodule MCP.OAuth.CIMDTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.CIMD
  alias MCP.TestSupport.CIMDTransportStub

  @scopes ["biomarkers:read", "records:read"]

  defp unique_client_id do
    "https://example.com/cimd-client/#{System.unique_integer([:positive])}"
  end

  defp opts(extra \\ []) do
    Keyword.merge([transport: CIMDTransportStub, cache: false, scopes: @scopes], extra)
  end

  describe "client_id?/1" do
    test "an https URL is a CIMD client_id" do
      assert CIMD.client_id?("https://example.com/client")
    end

    test "an opaque locally-issued id is not" do
      refute CIMD.client_id?("client_2f8a91c4")
    end

    test "http is not, so a lookalike never reaches the fetch path" do
      refute CIMD.client_id?("http://example.com/client")
    end

    test "an https URL with no host is not" do
      refute CIMD.client_id?("https:///client")
    end

    test "a non-binary id is not" do
      refute CIMD.client_id?(nil)
    end
  end

  describe "fetch_client/2" do
    test "builds a public, PKCE-enforced client from the document" do
      client_id = unique_client_id()

      CIMDTransportStub.stub_document(client_id, %{
        "client_name" => "Reader",
        "redirect_uris" => ["https://example.com/callback"]
      })

      assert {:ok, client} = CIMD.fetch_client(client_id, opts())
      assert client.id == client_id
      assert client.name == "Reader"
      assert client.redirect_uris == ["https://example.com/callback"]
      assert client.secret_hash == nil
      refute client.confidential?
      assert client.pkce_required?
      assert client.cimd?
    end

    test "intersects the document's requested scope with the host's" do
      client_id = unique_client_id()

      CIMDTransportStub.stub_document(client_id, %{
        "scope" => "biomarkers:read admin:everything"
      })

      assert {:ok, client} = CIMD.fetch_client(client_id, opts())
      assert client.scopes == ["biomarkers:read"]
    end

    test "a document with no scope gets the host's full declared set" do
      client_id = unique_client_id()
      CIMDTransportStub.stub_document(client_id)

      assert {:ok, client} = CIMD.fetch_client(client_id, opts())
      assert client.scopes == @scopes
    end

    test "a document asking only for unknown scopes is refused" do
      client_id = unique_client_id()
      CIMDTransportStub.stub_document(client_id, %{"scope" => "admin:everything"})

      assert :error = CIMD.fetch_client(client_id, opts())
    end

    test "client_credentials is refused: a CIMD client has no resource owner" do
      client_id = unique_client_id()
      CIMDTransportStub.stub_document(client_id, %{"grant_types" => ["client_credentials"]})

      assert :error = CIMD.fetch_client(client_id, opts())
    end

    test "a document with no redirect_uris is refused" do
      client_id = unique_client_id()

      CIMDTransportStub.stub(
        client_id,
        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{"client_id" => client_id}),
           headers: []
         }}
      )

      assert :error = CIMD.fetch_client(client_id, opts())
    end

    test "a redirect_uri the registration endpoint would refuse is refused here too" do
      client_id = unique_client_id()

      CIMDTransportStub.stub_document(client_id, %{
        "redirect_uris" => ["http://evil.example.com/callback"]
      })

      assert :error = CIMD.fetch_client(client_id, opts())
    end

    test "falls back to the client_id URL when the document names no client_uri" do
      client_id = unique_client_id()
      CIMDTransportStub.stub_document(client_id)

      assert {:ok, client} = CIMD.fetch_client(client_id, opts())
      assert client.client_uri == client_id
    end

    test "an unreachable document is an unknown client, not a leaked reason" do
      assert :error = CIMD.fetch_client(unique_client_id(), opts())
    end

    test "a private-address client_id is an unknown client" do
      assert :error = CIMD.fetch_client("https://127.0.0.1/client", opts())
    end

    test "with no :scopes, a client can ask for nothing" do
      client_id = unique_client_id()
      CIMDTransportStub.stub_document(client_id)

      assert {:ok, client} =
               CIMD.fetch_client(client_id, transport: CIMDTransportStub, cache: false)

      assert client.scopes == []
    end
  end
end
