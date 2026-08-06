defmodule MCP.Handle do
  @moduledoc """
  Signed + encrypted MRTR continuation state (`requestState`).

  The server stays stateless: everything needed to resume a paused tool call is
  sealed into the opaque handle with `Plug.Crypto`, keyed by the endpoint's
  `secret_key_base`. Tampered or expired handles fail verification.
  """

  @context "mcp.handle"
  @default_ttl_ms 600_000

  def default_ttl_ms, do: @default_ttl_ms

  # Seconds as a float: integer division would floor a sub-second TTL to 0,
  # which Plug.Crypto reads as already expired.
  def sign(secret_key_base, state, ttl_ms \\ @default_ttl_ms) do
    Plug.Crypto.encrypt(secret_key_base, @context, state, max_age: ttl_ms / 1000)
  end

  @spec verify(binary(), term()) :: {:ok, term()} | {:error, :expired | :invalid}
  def verify(secret_key_base, handle) when is_binary(handle) do
    case Plug.Crypto.decrypt(secret_key_base, @context, handle) do
      {:ok, state} -> {:ok, state}
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify(_secret_key_base, _handle), do: {:error, :invalid}
end
