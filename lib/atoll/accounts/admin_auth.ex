defmodule Atoll.Accounts.AdminAuth do
  @moduledoc "Separate operator authentication for administrative XRPC methods."

  def password_from_env!(nil), do: nil

  def password_from_env!(value) do
    if valid_password?(value),
      do: value,
      else: raise("ATOLL_ADMIN_PASSWORD must contain 32–1024 printable non-space ASCII bytes")
  end

  def authenticate(headers) do
    secret = Application.get_env(:atoll, :admin_password)

    if valid_password?(secret) do
      with [header] when is_binary(header) and byte_size(header) <= 2048 <- headers,
           true <- String.valid?(header),
           [scheme, encoded] <- String.split(header, " ", parts: 2),
           true <- String.downcase(scheme) == "basic",
           {:ok, decoded} <- Base.decode64(encoded),
           "admin:" <> password <- decoded,
           true <- valid_password?(password),
           true <-
             Plug.Crypto.secure_compare(
               :crypto.hash(:sha256, password),
               :crypto.hash(:sha256, secret)
             ) do
        :ok
      else
        _ -> {:error, :invalid_admin_credentials}
      end
    else
      {:error, :admin_not_configured}
    end
  end

  defp valid_password?(value),
    do:
      is_binary(value) and byte_size(value) in 32..1024 and
        Regex.match?(~r/\A[\x21-\x7e]+\z/, value)
end
