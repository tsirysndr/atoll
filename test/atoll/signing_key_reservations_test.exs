defmodule Atoll.SigningKeyReservationsTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{ReservedSigningKey, SigningKeyReservations}
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  @did "did:web:reserved.example.com"
  @other "did:web:other-reserved.example.com"

  setup do
    settings = [:key_encryption_key, :previous_key_encryption_keys, :reserved_signing_key_limit]
    prior = Map.new(settings, &{&1, Application.fetch_env(:atoll, &1)})
    master = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :key_encryption_key, master)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    Application.put_env(:atoll, :reserved_signing_key_limit, 10_000)

    on_exit(fn ->
      for {name, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    %{master: master}
  end

  test "DID retries are stable, anonymous reservations distinct, and admission is bounded" do
    Application.put_env(:atoll, :reserved_signing_key_limit, 3)
    assert {:ok, bound} = SigningKeyReservations.reserve(@did)
    assert {:ok, ^bound} = SigningKeyReservations.reserve(@did)
    assert {:ok, first} = SigningKeyReservations.reserve()
    assert {:ok, second} = SigningKeyReservations.reserve()
    assert length(Enum.uniq([bound, first, second])) == 3
    assert {:ok, %{curve: :k256}} = Multikey.from_did_key(bound.signingKey)
    assert {:error, :signing_key_reservations_full} = SigningKeyReservations.reserve(@other)
    assert {:ok, ^bound} = SigningKeyReservations.reserve(@did)
    assert Repo.aggregate(ReservedSigningKey, :count) == 3
    assert Repo.aggregate(Atoll.Repositories.Head, :count) == 0
    assert {:error, :invalid_request} = SigningKeyReservations.reserve("invalid")
    {:ok, _} = Repositories.create(@other, SigningKey.generate())
    assert {:error, :account_exists} = SigningKeyReservations.reserve(@other)
  end

  test "claim binds DID, retains custody on rollback and atomically installs the exact reserved key" do
    {:ok, %{signingKey: public}} = SigningKeyReservations.reserve(@did)

    assert {:error, :key_not_found} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@other, public) end)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               key = SigningKeyReservations.claim!(@did, public)
               assert {:ok, _} = Repositories.create(@did, key)
               assert {:ok, :stored} = KeyVault.store(@did, key)
               Repo.rollback(:abort)
             end)

    assert Repo.get(ReservedSigningKey, public)
    refute Repo.get(Atoll.Repositories.Head, @did)

    assert {:ok, :stored} =
             Repo.transaction(fn ->
               key = SigningKeyReservations.claim!(@did, public)
               assert {:ok, _} = Repositories.create(@did, key)
               {:ok, :stored} = KeyVault.store(@did, key)
               :stored
             end)

    refute Repo.get(ReservedSigningKey, public)
    {:ok, installed} = KeyVault.fetch(@did)
    assert {:ok, ^public} = Multikey.to_did_key(installed.curve, installed.public)

    assert {:error, :account_exists} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@did, public) end)
  end

  test "anonymous claims require the selected public key and unavailable custody fails closed",
       c do
    {:ok, %{signingKey: public}} = SigningKeyReservations.reserve()
    row = Repo.get!(ReservedSigningKey, public)
    assert byte_size(row.envelope) == 61
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    assert {:error, :key_decryption_failed} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@did, public) end)

    assert Repo.get!(ReservedSigningKey, public) == row
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])

    assert {:ok, %SigningKey{}} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@did, public) end)

    assert {:error, :key_not_found} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@other, public) end)
  end

  test "changing reservation identity or substituting ciphertext cannot redirect custody" do
    {:ok, %{signingKey: public}} = SigningKeyReservations.reserve(@did)
    {:ok, %{signingKey: other}} = SigningKeyReservations.reserve(@other)
    first = Repo.get!(ReservedSigningKey, public)
    second = Repo.get!(ReservedSigningKey, other)
    first |> Ecto.Changeset.change(envelope: second.envelope) |> Repo.update!()
    assert {:error, :key_decryption_failed} = SigningKeyReservations.reserve(@did)

    assert {:error, :key_decryption_failed} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@did, public) end)

    Repo.get!(ReservedSigningKey, public)
    |> Ecto.Changeset.change(did: nil, envelope: first.envelope)
    |> Repo.update!()

    assert {:error, :key_decryption_failed} =
             Repo.transaction(fn -> SigningKeyReservations.claim!(@other, public) end)

    assert Repo.aggregate(ReservedSigningKey, :count) == 2
  end

  test "bounded rewrap pages preserve public keys and no longer require the old master", c do
    for _ <- 1..3, do: assert({:ok, _} = SigningKeyReservations.reserve())
    old = Repo.all(from r in ReservedSigningKey, order_by: r.public_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = SigningKeyReservations.rewrap()
    assert Repo.all(from r in ReservedSigningKey, order_by: r.public_key) == old
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])

    assert {:ok, %{scanned: 2, rotated: 2, unchanged: 0, cursor: cursor}} =
             SigningKeyReservations.rewrap(2)

    assert {:ok, %{scanned: 1, rotated: 1, unchanged: 0}} =
             SigningKeyReservations.rewrap(2, cursor)

    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert {:ok, %{scanned: 3, rotated: 0, unchanged: 3}} = SigningKeyReservations.rewrap()

    assert Enum.map(
             Repo.all(from r in ReservedSigningKey, order_by: r.public_key),
             & &1.public_key
           ) == Enum.map(old, & &1.public_key)

    assert {:error, :invalid_rewrap_options} = SigningKeyReservations.rewrap(101)
    assert {:error, :invalid_rewrap_options} = SigningKeyReservations.rewrap(1, "bad")
  end

  test "a corrupt later envelope rolls back earlier rewraps in the same page", c do
    for _ <- 1..2, do: assert({:ok, _} = SigningKeyReservations.reserve())
    [first, second] = Repo.all(from r in ReservedSigningKey, order_by: r.public_key)
    second |> Ecto.Changeset.change(envelope: first.envelope) |> Repo.update!()
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:error, :key_decryption_failed} = SigningKeyReservations.rewrap()
    assert Repo.get!(ReservedSigningKey, first.public_key).envelope == first.envelope
  end
end
