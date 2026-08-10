defmodule MCP.OAuth.ConsentTest do
  # The plug addresses the Memory store by its global name, so no async.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MCP.OAuth.{Client, Store}

  @redirect "https://client.test/cb"
  @key_base String.duplicate("k", 64)

  setup do
    start_supervised!(Store.Memory)
    :ok
  end

  defmodule SignedIn do
    @behaviour MCP.OAuth.ResourceOwner
    def current_subject(_conn), do: {:ok, "member-1"}
    def fetch(sub), do: {:ok, sub}
  end

  defmodule OtherMember do
    @behaviour MCP.OAuth.ResourceOwner
    def current_subject(_conn), do: {:ok, "member-2"}
    def fetch(sub), do: {:ok, sub}
  end

  defmodule SignedOut do
    @behaviour MCP.OAuth.ResourceOwner
    def current_subject(_conn), do: :error
    def fetch(sub), do: {:ok, sub}
  end

  # Stands in for the host app's screen: echoes back everything the plug
  # offered, so a test can assert on the prompt without parsing markup.
  defmodule Screen do
    @behaviour MCP.OAuth.Consent

    @impl MCP.OAuth.Consent
    def render(conn, prompt) do
      body =
        Jason.encode!(%{
          "client_id" => prompt.client.id,
          "client_name" => prompt.client.name,
          "dynamically_registered" => prompt.client.dynamically_registered?,
          "scopes" => prompt.scopes,
          "subject" => prompt.subject,
          "grant_token" => prompt.grant_token,
          "action" => prompt.action
        })

      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  describe "GET with a consent screen" do
    test "renders consent instead of redirecting with a code" do
      client = public_client()
      conn = authorize(client, %{"scope" => "profile:read"})

      assert conn.status == 200
      assert get_resp_header(conn, "location") == []

      prompt = Jason.decode!(conn.resp_body)
      assert prompt["client_id"] == client.id
      assert prompt["client_name"] == "Claude"
      assert prompt["dynamically_registered"] == true
      assert prompt["scopes"] == ["profile:read"]
      assert prompt["subject"] == "member-1"
      assert prompt["grant_token"]
    end

    test "prompts for every declared scope when the request names none" do
      client = public_client()
      prompt = client |> authorize(%{}) |> body()

      assert prompt["scopes"] == ["profile:read", "biomarkers:read"]
    end

    test "an invalid request still errors before any screen is shown" do
      client = public_client()
      conn = authorize(client, %{"redirect_uri" => "https://evil.test/cb"})

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_request"
    end

    test "a signed-out request goes to sign-in, not to a consent screen" do
      client = public_client()
      conn = authorize(client, %{}, owner: SignedOut)

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/sign-in"]
    end

    test "with no consent module the endpoint still grants straight through" do
      client = public_client()
      conn = authorize(client, %{}, consent: nil)

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, @redirect <> "?")
      assert query(location)["code"]
    end
  end

  describe "POST back from the screen" do
    test "approve mints a code for exactly the consented scopes" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read", "state" => "xyz"})

      conn = decide(token, "approve")

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, @redirect <> "?")

      params = query(location)
      assert params["state"] == "xyz"
      assert code = params["code"]

      assert {:ok, stored} = Store.Memory.take_code(MCP.OAuth.Secret.hash(code))
      assert stored.scope == "profile:read"
      assert stored.sub == "member-1"
      assert stored.challenge == "abc"
    end

    test "deny redirects back with access_denied and no code" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read", "state" => "xyz"})

      conn = decide(token, "deny")

      assert conn.status == 302
      assert [location] = get_resp_header(conn, "location")

      params = query(location)
      assert params["error"] == "access_denied"
      assert params["state"] == "xyz"
      refute params["code"]
    end

    test "an unrecognised decision denies rather than granting" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read"})

      assert query_of(decide(token, "maybe"))["error"] == "access_denied"
    end

    test "a widened scope in the form is ignored: the signed request decides" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read"})

      conn =
        post_conn(%{
          "grant_token" => token,
          "decision" => "approve",
          "scope" => "profile:read biomarkers:read",
          "redirect_uri" => "https://evil.test/cb"
        })
        |> call()

      assert [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, @redirect <> "?")

      assert {:ok, stored} =
               Store.Memory.take_code(MCP.OAuth.Secret.hash(query(location)["code"]))

      assert stored.scope == "profile:read"
      assert stored.redirect_uri == @redirect
    end

    test "a forged or missing grant_token is a 400, never a redirect" do
      for body <- [
            %{"decision" => "approve"},
            %{"grant_token" => "forged", "decision" => "approve"}
          ] do
        conn = body |> post_conn() |> call()

        assert conn.status == 400
        assert get_resp_header(conn, "location") == []
        assert Jason.decode!(conn.resp_body)["error"] == "invalid_request"
      end
    end

    test "an expired screen cannot be approved" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read"})

      conn =
        %{"grant_token" => token, "decision" => "approve"}
        |> post_conn()
        |> call(consent_max_age: -1)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error_description"] == "expired_consent"
    end

    test "another member cannot approve the screen this one was shown" do
      client = public_client()
      token = grant_token(client, %{"scope" => "profile:read"})

      conn =
        %{"grant_token" => token, "decision" => "approve"}
        |> post_conn()
        |> call(owner: OtherMember)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error_description"] == "subject_changed"
    end
  end

  ## Helpers

  defp public_client do
    client = %Client{
      id: "dyn",
      secret_hash: nil,
      redirect_uris: [@redirect],
      scopes: ["profile:read", "biomarkers:read"],
      grant_types: ["authorization_code", "refresh_token"],
      confidential?: false,
      pkce_required?: true,
      name: "Claude",
      dynamically_registered?: true
    }

    :ok = Store.Memory.put_client(client)
    client
  end

  defp params(client, overrides) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "code_challenge" => "abc",
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end

  defp authorize(client, overrides, opts \\ []) do
    :get
    |> conn("/?" <> URI.encode_query(params(client, overrides)))
    |> with_key_base()
    |> call(opts)
  end

  defp grant_token(client, overrides),
    do: client |> authorize(overrides) |> body() |> Map.fetch!("grant_token")

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp decide(token, decision),
    do: %{"grant_token" => token, "decision" => decision} |> post_conn() |> call()

  defp post_conn(body), do: :post |> conn("/", body) |> with_key_base()

  defp with_key_base(conn), do: %{conn | secret_key_base: @key_base}

  defp call(conn, opts \\ []) do
    opts =
      Keyword.merge(
        [
          store: Store.Memory,
          resource_owner: Keyword.get(opts, :owner, SignedIn),
          consent: Screen,
          sign_in_path: "/sign-in"
        ],
        Keyword.drop(opts, [:owner])
      )

    MCP.OAuth.Plug.Authorize.call(conn, MCP.OAuth.Plug.Authorize.init(opts))
  end

  defp query(location), do: location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp query_of(conn), do: conn |> get_resp_header("location") |> List.first() |> query()
end
