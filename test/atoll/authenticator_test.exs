defmodule Atoll.AuthenticatorTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{Authenticator, TOTP, TOTPFactor, TOTPSecret, Credentials, Sessions}

  setup do
    for name <- [:session_signing_key, :key_encryption_key, :previous_key_encryption_keys] do
      previous = Application.fetch_env(:atoll, name)
      Application.put_env(:atoll, name, :crypto.strong_rand_bytes(32))

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    did = "did:plc:authenticator"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, "authenticator password")
    {:ok, pair} = Sessions.create(did, "authenticator password")
    %{did: did, pair: pair}
  end

  test "enrollment needs a full session and fresh password, stores only encrypted material", c do
    assert {:error, :invalid_credentials} =
             Authenticator.begin(c.pair.access_jwt, "wrong password")

    assert {:error, :invalid_token} =
             Authenticator.begin(c.pair.refresh_jwt, "authenticator password")

    assert {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    row = Repo.get!(TOTPFactor, c.did)
    assert row.confirmed_at == nil
    secret = Base.decode32!(enrollment.secret, padding: false)
    assert {:ok, ^secret} = TOTPSecret.open(c.did, row.envelope)
    assert :binary.match(row.envelope, secret) == :nomatch
    assert {:ok, _} = Sessions.create(c.did, "authenticator password")
    now = System.system_time(:second)
    {:ok, code} = TOTP.code(secret, now)
    assert {:ok, :enabled} = Authenticator.confirm(c.pair.access_jwt, code)
    assert Repo.get!(TOTPFactor, c.did).confirmed_at

    assert {:error, :totp_already_enabled} =
             Authenticator.begin(c.pair.access_jwt, "authenticator password")

    assert {:error, :totp_required} = Sessions.create(c.did, "authenticator password")

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: code)

    {:ok, next} = TOTP.code(secret, now + 30)
    assert {:ok, _} = Sessions.create(c.did, "authenticator password", totp_code: next)

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: next)
  end

  test "five attempts persist on failure, pending replacement cannot reset them", c do
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    secret = Base.decode32!(enrollment.secret, padding: false)

    for _ <- 1..5,
        do:
          assert(
            {:error, :invalid_totp} = Authenticator.confirm(c.pair.access_jwt, wrong_code(secret))
          )

    assert Repo.get!(TOTPFactor, c.did).attempts == 5
    assert {:ok, _} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    assert {:error, :totp_rate_limited} = Authenticator.confirm(c.pair.access_jwt, "000000")
    Repo.get!(TOTPFactor, c.did) |> Ecto.Changeset.change(window_started_at: 0) |> Repo.update!()
    assert {:error, :invalid_totp} = Authenticator.confirm(c.pair.access_jwt, "bad")
    assert Repo.get!(TOTPFactor, c.did).attempts == 1
  end

  test "expired pending enrollment and stale password proof cannot confirm", c do
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")

    {:ok, code} =
      TOTP.code(Base.decode32!(enrollment.secret, padding: false), System.system_time(:second))

    Repo.get!(TOTPFactor, c.did) |> Ecto.Changeset.change(pending_expires_at: 1) |> Repo.update!()
    assert {:error, :totp_enrollment_expired} = Authenticator.confirm(c.pair.access_jwt, code)
    {:ok, _} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    {:ok, hash} = Credentials.hash("replacement password")

    Repo.get!(Atoll.Accounts.Credential, c.did)
    |> Ecto.Changeset.change(password_hash: hash)
    |> Repo.update!()

    assert {:error, :totp_enrollment_expired} = Authenticator.confirm(c.pair.access_jwt, code)
  end

  test "session creation cannot skip a factor enabled after its admission", c do
    {:ok, digest} = Credentials.verified_digest(c.did, "authenticator password")
    assert {:ok, :disabled} = Authenticator.check_login(c.did, digest, nil)
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    secret = Base.decode32!(enrollment.secret, padding: false)
    {:ok, code} = TOTP.code(secret, System.system_time(:second))
    assert {:ok, :enabled} = Authenticator.confirm(c.pair.access_jwt, code)

    assert {:error, :totp_required} =
             Sessions.create_for_account(c.did,
               credential_digest: digest,
               totp_admission: :disabled
             )

    {:ok, next} = TOTP.code(secret, System.system_time(:second) + 30)
    {:ok, admission} = Authenticator.check_login(c.did, digest, next)

    assert {:error, :totp_required} =
             Sessions.create_for_account(c.did,
               credential_digest: digest,
               totp_admission: %{admission | expires_at: 1}
             )

    Repo.get!(TOTPFactor, c.did)
    |> Ecto.Changeset.change(
      version: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    )
    |> Repo.update!()

    assert {:error, :totp_required} =
             Sessions.create_for_account(c.did,
               credential_digest: digest,
               totp_admission: admission
             )
  end

  test "caller transactions cannot roll back admission or failed-attempt accounting", c do
    {:ok, digest} = Credentials.verified_digest(c.did, "authenticator password")

    assert {:ok, {:error, :totp_inside_transaction}} =
             Repo.transaction(fn -> Authenticator.check_login(c.did, digest, "000000") end)
  end

  test "a later session creation failure cannot make an admitted code reusable", c do
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    secret = Base.decode32!(enrollment.secret, padding: false)
    now = System.system_time(:second)
    {:ok, initial} = TOTP.code(secret, now)
    {:ok, :enabled} = Authenticator.confirm(c.pair.access_jwt, initial)
    {:ok, next} = TOTP.code(secret, now + 30)

    assert {:error, :session_configuration_missing} =
             Sessions.create(c.did, "authenticator password", totp_code: next, secret: nil)

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: next)

    assert Repo.get!(TOTPFactor, c.did).attempts == 3
  end

  test "operator rewrapping includes persisted authenticator secrets", c do
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    original = Repo.get!(TOTPFactor, c.did)
    old_key = Application.fetch_env!(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [old_key])
    assert {:ok, %{totp: 1}} = Atoll.KeyRewrap.batch()
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    row = Repo.get!(TOTPFactor, c.did)
    refute row.envelope == original.envelope
    assert row.version == original.version
    assert {:ok, secret} = TOTPSecret.open(c.did, row.envelope)
    assert Base.encode32(secret, padding: false) == enrollment.secret
    assert {:ok, %{totp: 0, unchanged: 1}} = Atoll.KeyRewrap.batch()
  end

  defp wrong_code(secret) do
    now = System.system_time(:second)

    valid =
      Enum.map([-30, 0, 30], fn offset ->
        {:ok, code} = TOTP.code(secret, now + offset)
        code
      end)

    Enum.find(~w(000000 000001 000002 000003), &(&1 not in valid))
  end
end
