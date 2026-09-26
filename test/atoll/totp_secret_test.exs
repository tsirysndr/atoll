defmodule Atoll.TOTPSecretTest do
  use ExUnit.Case, async: false
  alias Atoll.Accounts.{TOTP, TOTPSecret}
  @did "did:plc:totpsecret"

  setup do
    for key <- [:key_encryption_key, :previous_key_encryption_keys] do
      prior = Application.fetch_env(:atoll, key)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end)
    end

    master = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :key_encryption_key, master)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    %{master: master, secret: TOTP.generate_secret()}
  end

  test "randomized account-bound envelopes round-trip without plaintext", c do
    {:ok, envelope} = TOTPSecret.seal(@did, c.secret)
    {:ok, another} = TOTPSecret.seal(@did, c.secret)
    assert byte_size(envelope) == 49
    refute envelope == another
    assert :binary.match(envelope, c.secret) == :nomatch
    assert {:ok, secret} = TOTPSecret.open(@did, envelope)
    assert secret == c.secret
    assert {:error, :key_decryption_failed} = TOTPSecret.open("did:plc:otheraccount", envelope)
  end

  test "tampering and wrong active keys fail authentication", c do
    {:ok, envelope} = TOTPSecret.seal(@did, c.secret)

    for offset <- [1, 12, 13, 32, 33, 48] do
      <<before::binary-size(offset), byte, rest::binary>> = envelope
      tampered = <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>
      assert {:error, :key_decryption_failed} = TOTPSecret.open(@did, tampered)
    end

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = TOTPSecret.open(@did, envelope)
  end

  test "bounded fallback decryption and rewrap allow retirement of the old key", c do
    {:ok, old} = TOTPSecret.seal(@did, c.secret)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:ok, secret} = TOTPSecret.open(@did, old)
    assert secret == c.secret
    assert {:ok, rotated} = TOTPSecret.rewrap(@did, old)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert {:ok, ^secret} = TOTPSecret.open(@did, rotated)
    assert {:error, :key_decryption_failed} = TOTPSecret.open(@did, old)
  end

  test "malformed inputs and incomplete key configuration cannot yield secrets", c do
    for bad <- [nil, "", <<2, 0::384>>, :binary.copy(<<0>>, 5000)] do
      assert {:error, :invalid_totp_secret} = TOTPSecret.open(@did, bad)
    end

    for bad <- [nil, "", :crypto.strong_rand_bytes(19), :crypto.strong_rand_bytes(21)] do
      assert {:error, :invalid_totp_secret} = TOTPSecret.seal(@did, bad)
    end

    assert {:error, :invalid_totp_secret} = TOTPSecret.seal("invalid", c.secret)
    {:ok, envelope} = TOTPSecret.seal(@did, c.secret)
    Application.delete_env(:atoll, :key_encryption_key)
    assert {:error, :key_vault_unconfigured} = TOTPSecret.open(@did, envelope)
    assert {:error, :key_vault_unconfigured} = TOTPSecret.seal(@did, c.secret)
    Application.put_env(:atoll, :key_encryption_key, c.master)
    Application.put_env(:atoll, :previous_key_encryption_keys, List.duplicate(c.master, 5))
    assert {:error, :key_vault_unconfigured} = TOTPSecret.open(@did, envelope)
  end
end
