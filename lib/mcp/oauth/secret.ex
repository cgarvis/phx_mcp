defmodule MCP.OAuth.Secret do
  @moduledoc """
  Opaque secret generation and hashing for codes, tokens, and client secrets.

  Only the hash is ever stored or compared, and equality checks always go
  through `Plug.Crypto.secure_compare/2` — never `==` on a hash value.
  """

  @doc "32 random bytes, base64url-no-pad — the plaintext handed to the caller."
  @spec new() :: String.t()
  def new, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc "sha256 of a plaintext secret, as lowercase hex — the value that gets stored."
  @spec hash(String.t()) :: String.t()
  def hash(plaintext) when is_binary(plaintext),
    do: :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
end
