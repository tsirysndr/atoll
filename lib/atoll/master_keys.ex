defmodule Atoll.MasterKeys do
  @moduledoc "Active envelope encryption key and bounded decryption-only fallback keys."
  def previous_from_env!(nil), do: []
  def previous_from_env!(""), do: []

  def previous_from_env!(value) when is_binary(value) and byte_size(value) <= 256 do
    keys = String.split(value, ",")
    if length(keys) > 4, do: invalid!()

    Enum.map(keys, fn encoded ->
      case Base.decode64(String.trim(encoded)) do
        {:ok, <<_::256>> = key} -> key
        _ -> invalid!()
      end
    end)
    |> Enum.uniq()
  end

  def previous_from_env!(_), do: invalid!()

  def active do
    previous = Application.get_env(:atoll, :previous_key_encryption_keys, [])

    with <<_::256>> = key <- Application.get_env(:atoll, :key_encryption_key),
         true <-
           is_list(previous) and length(previous) <= 4 and
             Enum.all?(previous, &match?(<<_::256>>, &1)) do
      {:ok, key}
    else
      _ -> {:error, :key_vault_unconfigured}
    end
  end

  def decrypt(active, decrypt) do
    keys =
      [active | Application.get_env(:atoll, :previous_key_encryption_keys, [])] |> Enum.uniq()

    Enum.reduce_while(keys, {:error, :key_decryption_failed}, fn key, _ ->
      case decrypt.(key) do
        {:ok, _} = success -> {:halt, success}
        _ -> {:cont, {:error, :key_decryption_failed}}
      end
    end)
  end

  defp invalid!,
    do:
      raise(
        ArgumentError,
        "ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS must contain at most four comma-separated base64 32-byte keys"
      )
end
