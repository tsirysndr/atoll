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
    assert {:ok, %{recovery_codes: _}} = Authenticator.confirm(c.pair.access_jwt, code)
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
    assert {:ok, %{recovery_codes: _}} = Authenticator.confirm(c.pair.access_jwt, code)

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
    {:ok, %{recovery_codes: _}} = Authenticator.confirm(c.pair.access_jwt, initial)
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

  test "recovery codes are hashed, single-use, and do not disable the factor", c do
    codes = enroll(c)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10
    assert Enum.all?(codes, &Regex.match?(~r/\A[A-Z2-7]{26}\z/, &1))
    row = Repo.get!(TOTPFactor, c.did)
    assert length(row.recovery_hashes) == 10
    refute Enum.any?(codes, &(&1 in row.recovery_hashes))
    assert Enum.all?(row.recovery_hashes, &(byte_size(&1) == 32))
    assert {:ok, _} = Sessions.create(c.did, "authenticator password", totp_code: hd(codes))

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: hd(codes))

    assert {:error, :totp_required} = Sessions.create(c.did, "authenticator password")

    assert {:ok, %{state: :enabled, recovery_remaining: 9}} =
             Authenticator.status(c.pair.access_jwt)
  end

  test "replacing recovery codes invalidates old codes and pending login admission", c do
    [first, second, third | _] = enroll(c)
    {:ok, digest} = Credentials.verified_digest(c.did, "authenticator password")
    {:ok, admission} = Authenticator.check_login(c.did, digest, first)

    assert {:ok, %{recovery_codes: fresh}} =
             Authenticator.regenerate(c.pair.access_jwt, "authenticator password", second)

    assert length(fresh) == 10

    assert {:error, :totp_required} =
             Sessions.create_for_account(c.did,
               credential_digest: digest,
               totp_admission: admission
             )

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: third)

    assert {:ok, _} = Sessions.create(c.did, "authenticator password", totp_code: hd(fresh))
  end

  test "disabling requires fresh password and factor proof and permits new enrollment", c do
    codes = enroll(c)

    assert {:error, :invalid_credentials} =
             Authenticator.disable(c.pair.access_jwt, "wrong password", hd(codes))

    assert {:error, :invalid_totp} =
             Authenticator.disable(c.pair.access_jwt, "authenticator password", "bad")

    assert Repo.get!(TOTPFactor, c.did).attempts == 2

    assert {:ok, :disabled} =
             Authenticator.disable(c.pair.access_jwt, "authenticator password", hd(codes))

    refute Repo.get(TOTPFactor, c.did)
    assert {:ok, _} = Sessions.create(c.did, "authenticator password")
    assert {:ok, %{secret: _}} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
  end

  test "recovery and ordinary codes share the durable attempt budget", c do
    codes = enroll(c)

    for _ <- 1..4 do
      assert {:error, :invalid_totp} =
               Authenticator.regenerate(
                 c.pair.access_jwt,
                 "authenticator password",
                 "not a recovery code"
               )
    end

    assert {:error, :totp_rate_limited} =
             Sessions.create(c.did, "authenticator password", totp_code: hd(codes))

    assert {:error, :totp_rate_limited} =
             Authenticator.disable(c.pair.access_jwt, "authenticator password", hd(codes))

    assert length(Repo.get!(TOTPFactor, c.did).recovery_hashes) == 10
  end

  test "a recovery code stays consumed after a later login failure", c do
    codes = enroll(c)

    assert {:error, :session_configuration_missing} =
             Sessions.create(c.did, "authenticator password", totp_code: hd(codes), secret: nil)

    assert {:error, :invalid_totp} =
             Sessions.create(c.did, "authenticator password", totp_code: hd(codes))
  end

  test "restricted sessions cannot read or manage factors", c do
    codes = enroll(c)
    {:ok, app} = Atoll.Accounts.AppPasswords.create(c.pair.access_jwt, %{"name" => "restricted"})
    {:ok, pair} = Sessions.create(c.did, app.password)
    assert {:error, _} = Authenticator.status(pair.access_jwt)

    assert {:error, _} =
             Authenticator.regenerate(pair.access_jwt, "authenticator password", hd(codes))

    assert {:error, _} =
             Authenticator.disable(pair.access_jwt, "authenticator password", hd(codes))

    assert Repo.get!(TOTPFactor, c.did).attempts == 1
  end

  defp enroll(c) do
    {:ok, enrollment} = Authenticator.begin(c.pair.access_jwt, "authenticator password")
    secret = Base.decode32!(enrollment.secret, padding: false)
    {:ok, code} = TOTP.code(secret, System.system_time(:second))
    {:ok, %{recovery_codes: codes}} = Authenticator.confirm(c.pair.access_jwt, code)
    codes
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
