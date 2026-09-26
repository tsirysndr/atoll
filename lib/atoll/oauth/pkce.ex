defmodule Atoll.OAuth.PKCE do
  @moduledoc "S256 PKCE challenge syntax and constant-time verifier comparison."
  def challenge?(value) when is_binary(value) and byte_size(value) == 43 do
    with {:ok, <<_::256>> = bytes} <- Base.url_decode64(value, padding: false),
         do: Base.url_encode64(bytes, padding: false) == value,
         else: (_ -> false)
  end

  def challenge?(_), do: false

  def verify(verifier, challenge) when is_binary(verifier) and byte_size(verifier) in 43..128 do
    if challenge?(challenge) and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, verifier) do
      actual = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      Plug.Crypto.secure_compare(actual, challenge)
    else
      false
    end
  end

  def verify(_, _), do: false
end
