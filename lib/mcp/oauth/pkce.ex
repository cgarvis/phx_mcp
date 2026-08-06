defmodule MCP.OAuth.PKCE do
  @moduledoc """
  RFC 7636 Proof Key for Code Exchange — S256 only, "plain" is rejected.
  """

  @doc "Verifies a code_verifier against a stored code_challenge for the given method."
  @spec verify(String.t(), String.t(), String.t()) :: boolean()
  def verify(verifier, challenge, "S256") when is_binary(verifier) and is_binary(challenge) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  def verify(_verifier, _challenge, _method), do: false
end
