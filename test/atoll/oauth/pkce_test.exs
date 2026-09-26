defmodule Atoll.OAuth.PKCETest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.PKCE

  test "RFC 7636 S256 vector and verifier syntax boundaries" do
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    assert PKCE.challenge?(challenge)
    assert PKCE.verify(verifier, challenge)
    refute PKCE.verify(String.reverse(verifier), challenge)

    for invalid <- [
          nil,
          "",
          String.duplicate("x", 42),
          String.duplicate("x", 129),
          verifier <> "=",
          verifier <> " "
        ] do
      refute PKCE.verify(invalid, challenge)
    end

    for length <- [43, 128] do
      value = String.duplicate("~", length)
      hash = :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
      assert PKCE.verify(value, hash)
    end

    refute PKCE.challenge?(challenge <> "=")
    refute PKCE.challenge?(String.slice(challenge, 0, 42) <> "N")
  end
end
