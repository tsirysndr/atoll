defmodule Atoll.Accounts.EmailAddress do
  @moduledoc "Shared normalization for account email addresses."

  def normalize(value) when is_binary(value) and byte_size(value) <= 254 do
    case String.split(String.downcase(value), "@") do
      [local, domain] when byte_size(local) in 1..64 ->
        if Atoll.Syntax.handle?(domain) and
             Regex.match?(~r/\A[a-z0-9!#$%&'*+\/=?^_`{|}~.-]+\z/, local) and
             not String.starts_with?(local, ".") and not String.ends_with?(local, ".") and
             not String.contains?(local, ".."),
           do: {:ok, local <> "@" <> domain},
           else: {:error, :invalid_email}

      _ ->
        {:error, :invalid_email}
    end
  end

  def normalize(_), do: {:error, :invalid_email}
end
