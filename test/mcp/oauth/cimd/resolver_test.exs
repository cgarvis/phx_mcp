defmodule MCP.OAuth.CIMD.ResolverTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.CIMD.{Document, Resolver}
  alias MCP.TestSupport.CIMDTransportStub

  # example.com is real and always-public, so DNS/SSRF resolution runs for real;
  # only CIMDTransportStub's body is faked.
  defp unique_client_id do
    "https://example.com/cimd-test/#{System.unique_integer([:positive])}"
  end

  defp opts(extra \\ []) do
    Keyword.merge([transport: CIMDTransportStub, cache: false, max_redirects: 2], extra)
  end

  defp document_json(client_id) do
    Jason.encode!(%{
      "client_id" => client_id,
      "client_name" => "Resolver Test Client",
      "redirect_uris" => ["https://example.com/callback"],
      "grant_types" => ["authorization_code"]
    })
  end

  describe "resolve/2 -- happy path" do
    test "fetches, validates, and returns the document" do
      client_id = unique_client_id()

      CIMDTransportStub.stub(
        client_id,
        {:ok, %{status: 200, body: document_json(client_id), headers: []}}
      )

      assert {:ok, %Document{} = doc} = Resolver.resolve(client_id, opts())
      assert doc.client_id == client_id
      assert doc.metadata["client_name"] == "Resolver Test Client"
    end

    test "follows a bounded redirect, still validating client_id against the ORIGINAL URL" do
      # The document's declared client_id must equal `start`, not `final` -- binding
      # identity to wherever a redirect landed would let any host vouch for any URL.
      start = unique_client_id()
      final = unique_client_id()

      CIMDTransportStub.stub(
        start,
        {:ok, %{status: 302, body: "", headers: [{"location", final}]}}
      )

      CIMDTransportStub.stub(
        final,
        {:ok, %{status: 200, body: document_json(start), headers: []}}
      )

      assert {:ok, %Document{client_id: ^start}} = Resolver.resolve(start, opts())
    end

    test "rejects a redirect target serving a document for a different client_id" do
      start = unique_client_id()
      final = unique_client_id()

      CIMDTransportStub.stub(
        start,
        {:ok, %{status: 302, body: "", headers: [{"location", final}]}}
      )

      # final's document claims to BE final, not start -- must not validate.
      CIMDTransportStub.stub(
        final,
        {:ok, %{status: 200, body: document_json(final), headers: []}}
      )

      assert {:error, :client_id_mismatch} = Resolver.resolve(start, opts())
    end

    test "a redirect chain longer than max_redirects is rejected" do
      client_id = unique_client_id()
      # Redirects to itself: with max_redirects: 2 this must not loop forever.
      CIMDTransportStub.stub(
        client_id,
        {:ok, %{status: 302, body: "", headers: [{"location", client_id}]}}
      )

      assert {:error, :too_many_redirects} = Resolver.resolve(client_id, opts())
    end
  end

  describe "resolve/2 -- non-https rejection" do
    test "rejects a plain http client_id" do
      assert {:error, :not_https} = Resolver.resolve("http://example.com/client", opts())
    end

    test "rejects a non-URL client_id" do
      assert {:error, :not_https} = Resolver.resolve("not-a-url-at-all", opts())
    end

    test "rejects a client_id on a non-standard port" do
      assert {:error, :disallowed_port} =
               Resolver.resolve("https://example.com:8443/client", opts())
    end
  end

  describe "resolve/2 -- SSRF rejection" do
    test "rejects a client_id whose host is a private address literal" do
      assert {:error, {:disallowed_address, _address}} =
               Resolver.resolve("https://127.0.0.1/client", opts())
    end

    test "rejects the cloud instance-metadata address" do
      assert {:error, {:disallowed_address, _address}} =
               Resolver.resolve("https://169.254.169.254/client", opts())
    end

    test "rejects a redirect that targets a private address" do
      client_id = unique_client_id()

      CIMDTransportStub.stub(
        client_id,
        {:ok, %{status: 302, body: "", headers: [{"location", "https://127.0.0.1/pwn"}]}}
      )

      assert {:error, {:disallowed_address, _address}} = Resolver.resolve(client_id, opts())
    end
  end

  describe "resolve/2 -- cache behavior" do
    setup do
      table = :"cimd_cache_#{System.unique_integer([:positive])}"
      start_supervised!({MCP.OAuth.CIMD.Cache, name: table, table: table})
      %{cache_opts: opts(cache: MCP.OAuth.CIMD.Cache, cache_opts: [table: table])}
    end

    test "a second resolve for the same client_id does not re-fetch", %{cache_opts: cache_opts} do
      client_id = unique_client_id()

      CIMDTransportStub.stub(
        client_id,
        {:ok, %{status: 200, body: document_json(client_id), headers: []}}
      )

      assert {:ok, _doc} = Resolver.resolve(client_id, cache_opts)

      # Un-stubbing: a second real fetch would now get :fetch_failed instead of a cache hit.
      CIMDTransportStub.stub(client_id, {:error, :fetch_failed})

      assert {:ok, %Document{client_id: ^client_id}} = Resolver.resolve(client_id, cache_opts)
    end

    test "different client_ids are cached independently", %{cache_opts: cache_opts} do
      a = unique_client_id()
      b = unique_client_id()
      CIMDTransportStub.stub(a, {:ok, %{status: 200, body: document_json(a), headers: []}})

      assert {:ok, %Document{client_id: ^a}} = Resolver.resolve(a, cache_opts)
      # b was never stubbed -- proves the cache entry for `a` isn't served for `b`.
      assert {:error, :fetch_failed} = Resolver.resolve(b, cache_opts)
    end

    test "an expired entry re-fetches rather than serving a stale document", %{
      cache_opts: cache_opts
    } do
      client_id = unique_client_id()

      CIMDTransportStub.stub(
        client_id,
        {:ok, %{status: 200, body: document_json(client_id), headers: []}}
      )

      assert {:ok, _doc} = Resolver.resolve(client_id, Keyword.put(cache_opts, :cache_ttl_ms, 0))

      CIMDTransportStub.stub(client_id, {:error, :fetch_failed})

      assert {:error, :fetch_failed} = Resolver.resolve(client_id, cache_opts)
    end
  end

  describe "resolve/2 -- response handling" do
    test "a transport-reported oversized response is propagated, not swallowed" do
      # ReqTransport's real streaming cap needs a controllable slow HTTP server to
      # exercise; this covers error propagation only.
      client_id = unique_client_id()
      CIMDTransportStub.stub(client_id, {:error, :response_too_large})

      assert {:error, :response_too_large} = Resolver.resolve(client_id, opts())
    end

    test "a non-200, non-redirect status is rejected" do
      client_id = unique_client_id()
      CIMDTransportStub.stub(client_id, {:ok, %{status: 404, body: "", headers: []}})

      assert {:error, :invalid_status} = Resolver.resolve(client_id, opts())
    end

    test "a 200 response that isn't valid JSON is rejected" do
      client_id = unique_client_id()
      CIMDTransportStub.stub(client_id, {:ok, %{status: 200, body: "not json", headers: []}})

      assert {:error, :invalid_document} = Resolver.resolve(client_id, opts())
    end

    test "a document whose client_id does not match the URL is rejected" do
      client_id = unique_client_id()
      body = document_json(unique_client_id())
      CIMDTransportStub.stub(client_id, {:ok, %{status: 200, body: body, headers: []}})

      assert {:error, :client_id_mismatch} = Resolver.resolve(client_id, opts())
    end
  end
end
