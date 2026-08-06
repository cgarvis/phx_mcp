defmodule MCP.OAuth.PKCETest do
  use ExUnit.Case, async: true

  alias MCP.OAuth.PKCE

  test "S256: correct verifier matches the challenge" do
    verifier = "a-code-verifier-that-is-long-enough-per-rfc-7636"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    assert PKCE.verify(verifier, challenge, "S256")
  end

  test "S256: wrong verifier does not match" do
    verifier = "a-code-verifier-that-is-long-enough-per-rfc-7636"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    refute PKCE.verify("a-different-verifier", challenge, "S256")
  end

  test "any method other than S256 fails, even with a matching digest" do
    verifier = "a-code-verifier-that-is-long-enough-per-rfc-7636"
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    refute PKCE.verify(verifier, challenge, "plain")
    refute PKCE.verify(verifier, verifier, "plain")
    refute PKCE.verify(verifier, challenge, nil)
  end
end
