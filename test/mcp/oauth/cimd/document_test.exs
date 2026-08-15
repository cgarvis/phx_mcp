defmodule MCP.OAuth.CIMD.DocumentTest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.CIMD.Document

  @url "https://example.com/client"

  describe "parse/2" do
    test "accepts a document whose client_id is the URL it was fetched from" do
      json = %{"client_id" => @url, "redirect_uris" => ["https://example.com/cb"]}

      assert {:ok, %Document{client_id: @url} = doc} = Document.parse(@url, json)
      assert doc.metadata == json
      assert %DateTime{} = doc.fetched_at
    end

    test "rejects a document claiming a different client_id" do
      json = %{"client_id" => "https://other.example/client"}

      assert {:error, :client_id_mismatch} = Document.parse(@url, json)
    end

    test "rejects a document with no client_id at all" do
      assert {:error, :invalid_document} = Document.parse(@url, %{"redirect_uris" => []})
    end

    test "rejects a body that is not a JSON object" do
      assert {:error, :invalid_document} = Document.parse(@url, ["not", "an", "object"])
    end

    test "a trailing-slash difference is a mismatch: the match is exact" do
      json = %{"client_id" => @url <> "/"}

      assert {:error, :client_id_mismatch} = Document.parse(@url, json)
    end
  end
end
