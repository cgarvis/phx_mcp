defmodule MCP.HandleTest do
  use ExUnit.Case, async: true

  @secret String.duplicate("s", 64)

  test "round-trips arbitrary terms" do
    state = %{tool: "hold", principal: "alice", state: %{step: 1, ids: [1, 2]}}

    handle = MCP.Handle.sign(@secret, state)
    assert is_binary(handle)
    assert {:ok, ^state} = MCP.Handle.verify(@secret, handle)
  end

  test "tampered handles are invalid" do
    handle = MCP.Handle.sign(@secret, %{step: 1})

    assert {:error, :invalid} = MCP.Handle.verify(@secret, handle <> "tampered")
    assert {:error, :invalid} = MCP.Handle.verify(@secret, "garbage")
    assert {:error, :invalid} = MCP.Handle.verify(@secret, nil)
  end

  test "a different secret cannot verify" do
    handle = MCP.Handle.sign(@secret, %{step: 1})
    assert {:error, :invalid} = MCP.Handle.verify(String.duplicate("x", 64), handle)
  end

  test "expired handles are rejected" do
    handle = MCP.Handle.sign(@secret, %{step: 1}, -1000)
    assert {:error, :expired} = MCP.Handle.verify(@secret, handle)
  end

  # Integer division would floor these to a 0-second age, which reads as expired.
  test "a sub-second TTL is still a live handle" do
    for ttl_ms <- [500, 999] do
      handle = MCP.Handle.sign(@secret, %{step: 1}, ttl_ms)
      assert {:ok, %{step: 1}} = MCP.Handle.verify(@secret, handle)
    end
  end
end
