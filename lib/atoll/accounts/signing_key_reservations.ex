defmodule Atoll.Accounts.SigningKeyReservations do
  @moduledoc """
  Durable encrypted repository-key reservations. This internal module is not an
  authorization boundary. Claiming requires an authorized account-creation
  transaction with independently verified identity evidence selecting the key.
  Reservations never expire automatically: a DID may already refer to the key.
  """
  import Ecto.Query
  alias Atoll.{CBOR, MasterKeys, Multikey, Repo, SigningKey, Syntax}
  alias Atoll.Accounts.ReservedSigningKey
  alias Atoll.Repositories.{Events, Head}

  def reserve(did \\ nil) do
    with true <- is_nil(did) or Syntax.did?(did),
         {:ok, master} <- MasterKeys.active() do
      Repo.transaction(fn ->
        lock!()
        if did && Repo.get(Head, did), do: Repo.rollback(:account_exists)
        existing = if did, do: Repo.get_by(ReservedSigningKey, did: did)

        row =
          if existing do
            # Never return an unusable public key after loss of encryption custody.
            unwrap!(MasterKeys.decrypt(master, &decrypt(existing, &1)))
            existing
          else
            limit = Application.get_env(:atoll, :reserved_signing_key_limit, 10_000)

            unless is_integer(limit) and limit in 1..10_000,
              do: Repo.rollback(:invalid_reservation_limit)

            if Repo.aggregate(ReservedSigningKey, :count) >= limit,
              do: Repo.rollback(:signing_key_reservations_full)

            key = SigningKey.generate(:k256)
            {:ok, public} = Multikey.to_did_key(key.curve, key.public)
            row = %ReservedSigningKey{did: did, public_key: public}
            Repo.insert!(%{row | envelope: encrypt(row, key, master)}, log: false)
          end

        %{signingKey: row.public_key}
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(error, __STACKTRACE__)
  end

  @doc "Consumes selected custody inside the caller's authorized account-creation transaction."
  def claim!(did, public) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "key claim requires a transaction")
    unless Syntax.did?(did) and is_binary(public), do: Repo.rollback(:invalid_request)
    Events.lock!()
    if Repo.get(Head, did), do: Repo.rollback(:account_exists)

    row =
      Repo.one(from r in ReservedSigningKey, where: r.public_key == ^public, lock: "FOR UPDATE")

    unless row && row.did in [nil, did], do: Repo.rollback(:key_not_found)
    master = unwrap!(MasterKeys.active())
    key = unwrap!(MasterKeys.decrypt(master, &decrypt(row, &1)))
    Repo.delete!(row, log: false)
    key
  end

  @doc "Rewraps a bounded keyset page; callers must retain old master keys until all custody is migrated."
  def rewrap(limit \\ 100, cursor \\ nil)

  def rewrap(limit, cursor) when is_integer(limit) and limit in 1..100 do
    if is_nil(cursor) or valid_public?(cursor) do
      with {:ok, master} <- MasterKeys.active() do
        Repo.transaction(fn ->
          lock!()
          query = from r in ReservedSigningKey, order_by: r.public_key, limit: ^(limit + 1)
          query = if cursor, do: where(query, [r], r.public_key > ^cursor), else: query
          rows = Repo.all(query, log: false)
          page = Enum.take(rows, limit)

          rotated =
            Enum.count(page, fn row ->
              case decrypt(row, master) do
                {:ok, _} ->
                  false

                _ ->
                  key = unwrap!(MasterKeys.decrypt(master, &decrypt(row, &1)))

                  row
                  |> Ecto.Changeset.change(envelope: encrypt(row, key, master))
                  |> Repo.update!(log: false)

                  true
              end
            end)

          result = %{scanned: length(page), rotated: rotated, unchanged: length(page) - rotated}

          if length(rows) > limit,
            do: Map.put(result, :cursor, List.last(page).public_key),
            else: result
        end)
      end
    else
      {:error, :invalid_rewrap_options}
    end
  rescue
    _ in Postgrex.Error -> {:error, :rewrap_failed}
  end

  def rewrap(_, _), do: {:error, :invalid_rewrap_options}

  defp lock! do
    Repo.query!("SET LOCAL lock_timeout = '1s'")
    Repo.query!("SET LOCAL statement_timeout = '5s'")
    Events.lock!()
  end

  defp valid_public?(value) when is_binary(value) and byte_size(value) <= 256,
    do: match?({:ok, %{curve: :k256}}, Multikey.from_did_key(value))

  defp valid_public?(_), do: false

  defp aad(row), do: CBOR.encode!(["atoll.reserved-repository-key.v1", row.did, row.public_key])

  defp encrypt(row, key, master) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, key.private, aad(row), 16, true)

    <<1, nonce::binary, ciphertext::binary, tag::binary>>
  end

  defp decrypt(
         %{
           envelope:
             <<1, nonce::binary-size(12), ciphertext::binary-size(32), tag::binary-size(16)>>
         } = row,
         master
       ) do
    with private when is_binary(private) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master,
             nonce,
             ciphertext,
             aad(row),
             tag,
             false
           ),
         {:ok, key} <- SigningKey.from_private(:k256, private),
         {:ok, public} <- Multikey.to_did_key(key.curve, key.public),
         true <- public == row.public_key do
      {:ok, key}
    else
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp decrypt(_, _), do: {:error, :key_decryption_failed}
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
