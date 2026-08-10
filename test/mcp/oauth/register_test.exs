defmodule MCP.OAuth.RegisterTest do
  # The plug addresses the Memory store by its global name, so no async.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MCP.OAuth.Store

  @scopes ["profile:read", "biomarkers:read"]

  setup do
    start_supervised!(Store.Memory)
    :ok
  end

  # A limiter that says yes `allow` times and no after that -- the real one is
  # the host app's, and the plug only cares about the two return shapes.
  defmodule Limiter do
    def check(key, allow: allow) do
      count =
        Agent.get_and_update(
          __MODULE__,
          &{Map.get(&1, key, 0) + 1, Map.update(&1, key, 1, fn n -> n + 1 end)}
        )

      if count <= allow, do: :ok, else: {:error, :rate_limited, 30_000}
    end

    def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  describe "POST /oauth/register" do
    test "registers a client and returns it without a secret" do
      conn = register(%{"client_name" => "Claude", "redirect_uris" => [callback()]})

      assert conn.status == 201
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      body = Jason.decode!(conn.resp_body)
      assert body["client_name"] == "Claude"
      assert body["redirect_uris"] == [callback()]
      assert body["token_endpoint_auth_method"] == "none"
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
      assert body["scope"] == "profile:read biomarkers:read"
      assert is_integer(body["client_id_issued_at"])
      refute Map.has_key?(body, "client_secret")

      # The registered client is immediately usable at the authorize endpoint.
      assert {:ok, client} = Store.Memory.get_client(body["client_id"])
      assert client.dynamically_registered?
      assert client.pkce_required?
      refute client.confidential?
    end

    test "narrows the scope to what the AS declares" do
      conn = register(%{"redirect_uris" => [callback()], "scope" => "profile:read admin:all"})

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["scope"] == "profile:read"
    end

    test "rejects client_credentials with a 400 and stores nothing" do
      conn =
        register(%{
          "redirect_uris" => [callback()],
          "grant_types" => ["client_credentials"]
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_client_metadata"
      assert body["error_description"] =~ "client_credentials"
    end

    test "rejects a redirect_uri that is not https or loopback" do
      conn = register(%{"redirect_uris" => ["http://evil.test/cb"]})

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_redirect_uri"
    end

    test "a store failure is a 500, not a 201" do
      defmodule RefusingStore do
        @behaviour MCP.OAuth.Store
        def put_client(_client), do: {:error, :nope}
        def get_client(_id), do: :error
        def put_code(_code), do: :ok
        def take_code(_hash), do: :error
        def put_token(_token), do: :ok
        def get_token(_hash), do: :error
        def get_refresh(_hash), do: :error
        def revoke_token(_hash), do: :ok
      end

      conn =
        :post
        |> conn("/", Jason.encode!(%{"redirect_uris" => [callback()]}))
        |> put_req_header("content-type", "application/json")
        |> parse()
        |> call(store: RefusingStore, scopes: @scopes)

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "server_error"
      # The store's own reason is logged, not handed to an unauthenticated caller.
      refute body["error_description"] =~ "nope"
    end

    test "GET is a 405" do
      conn = :get |> conn("/") |> call(store: Store.Memory, scopes: @scopes)

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  describe "rate limiting" do
    setup do
      start_supervised!(%{id: Limiter, start: {Limiter, :start, []}})
      :ok
    end

    test "429s past the per-IP budget, with a retry-after" do
      opts = [
        store: Store.Memory,
        scopes: @scopes,
        rate_limit: {Limiter, :check, [allow: 1]}
      ]

      assert register(%{"redirect_uris" => [callback()]}, opts).status == 201

      conn = register(%{"redirect_uris" => [callback()]}, opts)
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["31"]
      assert Jason.decode!(conn.resp_body)["error"] == "temporarily_unavailable"
    end
  end

  ## Helpers

  defp callback, do: "https://claude.ai/api/mcp/auth_callback"

  defp register(metadata, opts \\ [store: Store.Memory, scopes: @scopes]) do
    :post
    |> conn("/", Jason.encode!(metadata))
    |> put_req_header("content-type", "application/json")
    |> parse()
    |> call(opts)
  end

  defp parse(conn) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)
    )
  end

  defp call(conn, opts),
    do: MCP.OAuth.Plug.Register.call(conn, MCP.OAuth.Plug.Register.init(opts))
end
