defmodule MCP.OAuth.PlugTest do
  # The plugs address the Memory store by its global name, so no async.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MCP.OAuth.{Client, Secret, Store}

  @issuer "https://as.test"
  @resource "https://as.test/mcp"
  @redirect "https://client.test/cb"

  setup do
    start_supervised!(Store.Memory)
    :ok
  end

  # A resource owner the plug sees as signed in, and one it does not.
  defmodule SignedIn do
    @behaviour MCP.OAuth.ResourceOwner
    def current_subject(_conn), do: {:ok, "member-1"}
    def fetch(sub), do: {:ok, sub}
  end

  defmodule SignedOut do
    @behaviour MCP.OAuth.ResourceOwner
    def current_subject(_conn), do: :error
    def fetch(sub), do: {:ok, sub}
  end

  describe "MCP.OAuth.Plug.Metadata" do
    test "advertises the endpoints under the issuer and mount prefix" do
      body =
        :get
        |> conn("/")
        |> call(MCP.OAuth.Plug.Metadata, issuer: @issuer, scopes: ["profile:read"])
        |> json()

      assert body["issuer"] == @issuer
      assert body["authorization_endpoint"] == @issuer <> "/oauth/authorize"
      assert body["token_endpoint"] == @issuer <> "/oauth/token"
      assert body["scopes_supported"] == ["profile:read"]
      assert body["code_challenge_methods_supported"] == ["S256"]
      refute Map.has_key?(body, "jwks_uri")
    end
  end

  describe "MCP.OAuth.Plug.Token, action :token" do
    test "issues a client_credentials token and forbids caching" do
      client = confidential_client("s3cret")

      conn =
        :post
        |> conn("/", %{
          "grant_type" => "client_credentials",
          "client_id" => client.id,
          "client_secret" => "s3cret",
          "scope" => "profile:read"
        })
        |> call(MCP.OAuth.Plug.Token, store: Store.Memory, default_resource: @resource)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      body = json(conn)
      assert body["token_type"] == "bearer"
      assert body["access_token"]
    end

    test "a bad secret is a 401 invalid_client" do
      client = confidential_client("s3cret")

      body =
        :post
        |> conn("/", %{
          "grant_type" => "client_credentials",
          "client_id" => client.id,
          "client_secret" => "wrong",
          "scope" => "profile:read"
        })
        |> call(MCP.OAuth.Plug.Token, store: Store.Memory)
        |> json(401)

      assert body["error"] == "invalid_client"
    end
  end

  describe "MCP.OAuth.Plug.Token, introspect and revoke" do
    test "an issued token is active until revoked" do
      client = confidential_client("s3cret")
      token = client_credentials_token(client)

      assert introspect(client, token)["active"] == true

      :post
      |> conn("/", %{"client_id" => client.id, "client_secret" => "s3cret", "token" => token})
      |> call(MCP.OAuth.Plug.Token, action: :revoke, store: Store.Memory)

      assert introspect(client, token) == %{"active" => false}
    end
  end

  describe "MCP.OAuth.Plug.Authorize" do
    test "a signed-in owner is redirected back with a code" do
      client = public_client()

      conn =
        authorize_conn(%{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "scope" => "profile:read",
          "state" => "xyz",
          "code_challenge" => "abc",
          "code_challenge_method" => "S256"
        })
        |> call(MCP.OAuth.Plug.Authorize, authorize_opts(SignedIn))

      assert conn.status == 302
      location = conn |> get_resp_header("location") |> List.first()
      params = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert String.starts_with?(location, @redirect <> "?")
      assert params["state"] == "xyz"
      assert params["code"]
    end

    test "an unknown redirect_uri is a 400, never a redirect" do
      client = public_client()

      conn =
        authorize_conn(%{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => "https://evil.test/cb",
          "code_challenge" => "abc",
          "code_challenge_method" => "S256"
        })
        |> call(MCP.OAuth.Plug.Authorize, authorize_opts(SignedIn))

      assert conn.status == 400
      assert get_resp_header(conn, "location") == []
      assert json(conn, 400)["error"] == "invalid_request"
    end

    test "a signed-out request goes to the sign-in path, not the client" do
      client = public_client()

      conn =
        authorize_conn(%{
          "response_type" => "code",
          "client_id" => client.id,
          "redirect_uri" => @redirect
        })
        |> call(MCP.OAuth.Plug.Authorize, authorize_opts(SignedOut))

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/sign-in"]
    end
  end

  describe "MCP.Auth.OAuth" do
    test "verifies a token the store issued and binds it to the resource" do
      client = confidential_client("s3cret")
      token = client_credentials_token(client)
      opts = [store: Store.Memory, resource: @resource]

      assert {:ok, %MCP.Context{principal: "client:" <> _, scopes: ["profile:read"]}} =
               MCP.Auth.OAuth.verify(conn(:post, "/"), token, opts)

      assert {:error, :invalid_token} =
               MCP.Auth.OAuth.verify(conn(:post, "/"), "nope", opts)
    end

    test "refuses a token minted for a different resource" do
      client = confidential_client("s3cret")
      token = client_credentials_token(client)

      assert {:error, :invalid_token} =
               MCP.Auth.OAuth.verify(conn(:post, "/"), token,
                 store: Store.Memory,
                 resource: "https://other.test/mcp"
               )
    end
  end

  ## Helpers

  defp call(conn, plug, opts), do: plug.call(conn, plug.init(opts))

  defp authorize_conn(params), do: conn(:get, "/?" <> URI.encode_query(params))

  defp authorize_opts(owner) do
    [
      store: Store.Memory,
      resource_owner: owner,
      sign_in_path: "/sign-in",
      default_resource: @resource
    ]
  end

  defp introspect(client, token) do
    :post
    |> conn("/", %{"client_id" => client.id, "client_secret" => "s3cret", "token" => token})
    |> call(MCP.OAuth.Plug.Token, action: :introspect, store: Store.Memory, issuer: @issuer)
    |> json()
  end

  defp client_credentials_token(client) do
    :post
    |> conn("/", %{
      "grant_type" => "client_credentials",
      "client_id" => client.id,
      "client_secret" => "s3cret",
      "scope" => "profile:read"
    })
    |> call(MCP.OAuth.Plug.Token, store: Store.Memory, default_resource: @resource)
    |> json()
    |> Map.fetch!("access_token")
  end

  defp public_client do
    client = %Client{
      id: "pub",
      secret_hash: nil,
      redirect_uris: [@redirect],
      scopes: ["profile:read"],
      grant_types: ["authorization_code", "refresh_token"],
      confidential?: false,
      pkce_required?: true
    }

    :ok = Store.Memory.put_client(client)
    client
  end

  defp confidential_client(secret) do
    client = %Client{
      id: "mach",
      secret_hash: Secret.hash(secret),
      redirect_uris: [],
      scopes: ["profile:read"],
      grant_types: ["client_credentials"],
      confidential?: true,
      pkce_required?: false
    }

    :ok = Store.Memory.put_client(client)
    client
  end

  defp json(conn, status \\ 200) do
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end
end
