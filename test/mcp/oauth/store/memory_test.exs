defmodule MCP.OAuth.Store.MemoryTest do
  # Shares the named MCP.OAuth.Store.Memory process with other oauth tests.
  use ExUnit.Case, async: false

  alias MCP.OAuth.Code
  alias MCP.OAuth.Store.Memory

  setup do
    start_supervised!(Memory)
    :ok
  end

  test "take_code is delete-on-read: the second take on the same hash gets :error" do
    code = %Code{
      code_hash: "deadbeef",
      client_id: "client-1",
      redirect_uri: "https://client.test/cb",
      scope: "mcp:read",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    :ok = Memory.put_code(code)

    assert {:ok, ^code} = Memory.take_code("deadbeef")
    assert :error = Memory.take_code("deadbeef")
  end

  test "take_code is atomic under concurrent callers -- exactly one of N takers wins" do
    code = %Code{
      code_hash: "racehash",
      client_id: "client-1",
      redirect_uri: "https://client.test/cb",
      scope: "mcp:read",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    :ok = Memory.put_code(code)

    results =
      1..20
      |> Task.async_stream(fn _ -> Memory.take_code("racehash") end, timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, code})) == 1
    assert Enum.count(results, &(&1 == :error)) == 19
  end

  test "get_client returns :error for an unregistered id" do
    assert :error = Memory.get_client("nope")
  end
end
