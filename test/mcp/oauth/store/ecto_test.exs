defmodule MCP.OAuth.Store.EctoTest do
  # Touches Postgres; excluded by default (see test/test_helper.exs). One
  # shared MCP.Test.Repo connection means one module, async: false, the same
  # reasoning MemoryTest documents for its own shared process.
  use MCP.EctoCase, async: false
  @moduletag :ecto

  alias MCP.OAuth.{Client, Code, Secret, Token}
  alias MCP.Test.OAuthStore, as: Store
  alias MCP.Test.OAuthStorePrefixed, as: PrefixedStore
  alias MCP.Test.Repo

  defp client_fixture(attrs) do
    %Client{
      id: Map.get(attrs, :id, "client-" <> Secret.new()),
      secret_hash: Map.get(attrs, :secret_hash, Secret.new()),
      redirect_uris: Map.get(attrs, :redirect_uris, ["https://client.test/callback"]),
      scopes: Map.get(attrs, :scopes, ["mcp:read", "mcp:write"]),
      grant_types: Map.get(attrs, :grant_types, ["authorization_code", "refresh_token"]),
      confidential?: Map.get(attrs, :confidential?, true),
      pkce_required?: Map.get(attrs, :pkce_required?, false),
      name: Map.get(attrs, :name, "Test Client"),
      client_uri: Map.get(attrs, :client_uri),
      logo_uri: Map.get(attrs, :logo_uri),
      dynamically_registered?: Map.get(attrs, :dynamically_registered?, false),
      cimd?: Map.get(attrs, :cimd?, false)
    }
  end

  defp client_fixture, do: client_fixture(%{})

  defp code_fixture(attrs) do
    %Code{
      code_hash: Map.get(attrs, :code_hash, Secret.new()),
      client_id: Map.get(attrs, :client_id, "client-1"),
      redirect_uri: Map.get(attrs, :redirect_uri, "https://client.test/callback"),
      challenge: Map.get(attrs, :challenge, "challenge-value"),
      challenge_method: Map.get(attrs, :challenge_method, "S256"),
      scope: Map.get(attrs, :scope, "mcp:read"),
      sub: Map.get(attrs, :sub, "user-1"),
      resource: Map.get(attrs, :resource, "https://api.test/mcp"),
      expires_at: Map.get(attrs, :expires_at, future())
    }
  end

  defp code_fixture, do: code_fixture(%{})

  defp token_fixture(attrs) do
    %Token{
      access_hash: Map.get(attrs, :access_hash, Secret.new()),
      refresh_hash: Map.get(attrs, :refresh_hash, Secret.new()),
      client_id: Map.get(attrs, :client_id, "client-1"),
      sub: Map.get(attrs, :sub, "user-1"),
      scope: Map.get(attrs, :scope, "mcp:read"),
      audience: Map.get(attrs, :audience, ["https://api.test/mcp"]),
      expires_at: Map.get(attrs, :expires_at, future())
    }
  end

  defp token_fixture, do: token_fixture(%{})

  # Pre-truncated so the round-tripped struct is a byte-for-byte match: the
  # column is :utc_datetime, and MCP.OAuth.Store.Ecto truncates on the way in
  # (see its moduledoc), so an un-truncated fixture would never compare equal
  # to what comes back out.
  defp future, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600, :second)

  describe "clients" do
    test "put_client/1 and get_client/1 round trip every field" do
      client = client_fixture()
      assert :ok = Store.put_client(client)
      assert {:ok, ^client} = Store.get_client(client.id)
    end

    test "get_client/1 returns :error for an unknown id" do
      assert :error = Store.get_client("does-not-exist")
    end

    test "a public client (secret_hash: nil, pkce_required?: true) round trips" do
      client = client_fixture(%{secret_hash: nil, confidential?: false, pkce_required?: true})
      assert :ok = Store.put_client(client)
      assert {:ok, ^client} = Store.get_client(client.id)
    end

    test "a confidential client that still requires PKCE round trips" do
      # The case Moxie's derived pkce_required? (not confidential?) cannot
      # express -- see MCP.OAuth.Store.Ecto.Client's moduledoc.
      client = client_fixture(%{confidential?: true, pkce_required?: true})
      assert :ok = Store.put_client(client)
      assert {:ok, ^client} = Store.get_client(client.id)
    end

    test "dynamically_registered?, cimd?, and name: nil round trip" do
      client = client_fixture(%{dynamically_registered?: true, cimd?: true, name: nil})
      assert :ok = Store.put_client(client)
      assert {:ok, ^client} = Store.get_client(client.id)
    end

    test "put_client/1 on a duplicate id returns {:error, changeset}, not a raise" do
      client = client_fixture()
      assert :ok = Store.put_client(client)
      assert {:error, %Ecto.Changeset{}} = Store.put_client(client_fixture(%{id: client.id}))
    end
  end

  describe "codes" do
    test "put_code/1 and take_code/1 round trip, then delete on read" do
      code = code_fixture()
      assert :ok = Store.put_code(code)
      assert {:ok, ^code} = Store.take_code(code.code_hash)
      assert :error = Store.take_code(code.code_hash)
    end

    test "take_code/1 returns :error for an unknown hash" do
      assert :error = Store.take_code("does-not-exist")
    end

    test "an unscoped code's \"\" scope survives the round trip" do
      code = code_fixture(%{scope: ""})
      assert :ok = Store.put_code(code)
      assert {:ok, %Code{scope: ""}} = Store.take_code(code.code_hash)
    end

    # The correctness requirement c:MCP.OAuth.Store.take_code/1 documents:
    # two concurrent callers racing the same hash must not both win. Shared
    # sandbox mode is what lets the spawned tasks reach the same connection
    # this test process checked out; the atomicity itself comes from
    # DELETE ... RETURNING in MCP.OAuth.Store.Ecto.take_code/3, not from
    # anything the test does.
    test "take_code/1 is atomic under concurrent callers -- exactly one of N takers wins" do
      code = code_fixture()
      :ok = Store.put_code(code)

      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      results =
        1..20
        |> Task.async_stream(fn _ -> Store.take_code(code.code_hash) end, timeout: :infinity)
        |> Enum.map(fn {:ok, result} -> result end)

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      assert Enum.count(results, &(&1 == {:ok, code})) == 1
      assert Enum.count(results, &(&1 == :error)) == 19
    end
  end

  describe "tokens" do
    test "put_token/1 and get_token/1 round trip" do
      token = token_fixture()
      assert :ok = Store.put_token(token)
      assert {:ok, ^token} = Store.get_token(token.access_hash)
    end

    test "get_token/1 returns :error for an unknown hash" do
      assert :error = Store.get_token("does-not-exist")
    end

    test "get_refresh/1 finds the same token by its refresh hash" do
      token = token_fixture()
      assert :ok = Store.put_token(token)
      assert {:ok, ^token} = Store.get_refresh(token.refresh_hash)
    end

    test "get_refresh/1 returns :error for an unknown hash" do
      assert :error = Store.get_refresh("does-not-exist")
    end

    test "revoke_token/1 makes get_token/1 return revoked?: true" do
      token = token_fixture()
      :ok = Store.put_token(token)

      assert :ok = Store.revoke_token(token.access_hash)
      assert {:ok, %Token{revoked?: true}} = Store.get_token(token.access_hash)
    end

    test "revoke_token/1 on an unknown hash is a no-op, not an error" do
      assert :ok = Store.revoke_token("does-not-exist")
    end

    test "a client_credentials token (sub: nil, no refresh_hash) round trips" do
      token = token_fixture(%{sub: nil, refresh_hash: nil})
      assert :ok = Store.put_token(token)
      assert {:ok, ^token} = Store.get_token(token.access_hash)
    end

    test "an unscoped token's \"\" scope survives the round trip" do
      token = token_fixture(%{scope: ""})
      assert :ok = Store.put_token(token)
      assert {:ok, %Token{scope: ""}} = Store.get_token(token.access_hash)
    end
  end

  describe ":prefix option" do
    test "a store configured with prefix: \"public\" still round trips" do
      client = client_fixture()
      assert :ok = PrefixedStore.put_client(client)
      assert {:ok, ^client} = PrefixedStore.get_client(client.id)
    end
  end
end
