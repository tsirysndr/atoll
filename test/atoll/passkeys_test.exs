defmodule Atoll.PasskeysTest do
  use Atoll.DataCase, async: false

  alias Atoll.Accounts.{
    Passkeys,
    Passkey,
    PasskeyUser,
    PasskeyChallenge,
    Credentials,
    Sessions,
    Session,
    Tokens,
    Authenticator,
    TOTP
  }

  alias Atoll.PasskeyFixtures, as: Fixture
  @password "passkey account password"

  setup do
    prior =
      Map.new(
        [:session_signing_key, :key_encryption_key, :passkeys_enabled, :session_max_count],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :passkeys_enabled, true)
    Application.put_env(:atoll, :session_max_count, 100)

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    did = "did:plc:passkeyaccount"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, @password)
    {:ok, pair} = Sessions.create(did, @password)
    %{did: did, pair: pair, browser: random()}
  end

  test "enrollment and discoverable login persist public keys and bind revocable sessions", c do
    {credential, fixture} = enroll(c)
    assert Repo.get!(PasskeyUser, c.did).user_handle == fixture.stored.user_handle
    row = Repo.get!(Passkey, credential.id)
    assert row.public_key == fixture.stored.public_key
    assert row.sign_count == 0
    refute Map.has_key?(Map.from_struct(row), :private_key)
    {:ok, request} = Passkeys.begin_login(c.browser)
    refute Map.has_key?(request.public_key, :allowCredentials)
    assert request.public_key.userVerification == "required"
    fixture = %{fixture | context: Fixture.context(request.public_key)}
    response = Fixture.assertion(fixture)
    assert {:ok, pair} = Passkeys.complete_login(c.browser, request.reference, response)
    assert {:ok, %{did: did}} = Sessions.authenticate_management(pair.access_jwt)
    assert did == c.did
    {:ok, claims} = Tokens.verify(pair.access_jwt, :access)
    assert Repo.get!(Session, claims["sid"]).passkey_id == credential.id

    grant =
      Repo.insert!(%Atoll.OAuth.Session{
        id: random(),
        did: c.did,
        source_session_id: claims["sid"],
        issuer: AtollWeb.Endpoint.url(),
        client_id: "https://app.example.com/meta",
        scope: "atproto",
        dpop_jkt: random(),
        expires_at: System.system_time(:second) + 600
      })

    access =
      Repo.insert!(%Atoll.OAuth.AccessToken{
        digest: :crypto.strong_rand_bytes(32),
        session_id: grant.id,
        scope: "atproto",
        expires_at: grant.expires_at
      })

    assert Repo.get!(Passkey, credential.id).sign_count == 1
    assert Repo.get!(Passkey, credential.id).last_used_at

    assert {:error, :invalid_passkey} =
             Passkeys.complete_login(c.browser, request.reference, response)

    assert Repo.aggregate(PasskeyChallenge, :count) == 0
    {:ok, entries} = Passkeys.list(c.pair.access_jwt)
    assert [%{id: id, name: "Laptop"}] = entries
    assert id == credential.id
    refute Map.has_key?(hd(entries), :credential_id)
    assert {:ok, :revoked} = Passkeys.revoke(c.pair.access_jwt, @password, credential.id)
    refute Repo.get(Atoll.OAuth.Session, grant.id)
    refute Repo.get(Atoll.OAuth.AccessToken, access.digest)
    assert {:error, _} = Sessions.authenticate_management(pair.access_jwt)
    assert {:ok, _} = Sessions.authenticate_management(c.pair.access_jwt)
    assert {:ok, []} = Passkeys.list(c.pair.access_jwt)
  end

  test "fresh password, full session and configured origin are required", c do
    assert {:error, :invalid_credentials} =
             Passkeys.begin_registration(
               c.pair.access_jwt,
               "incorrect password",
               c.browser,
               "Key"
             )

    assert {:error, _} =
             Passkeys.begin_registration(c.pair.refresh_jwt, @password, c.browser, "Key")

    {:ok, app} = Atoll.Accounts.AppPasswords.create(c.pair.access_jwt, %{"name" => "app"})
    {:ok, pair} = Sessions.create(c.did, app.password)
    assert {:error, _} = Passkeys.begin_registration(pair.access_jwt, @password, c.browser, "Key")

    for {browser, name} <- [
          {"bad", "Key"},
          {c.browser, ""},
          {c.browser, String.duplicate("x", 65)},
          {c.browser, "newline\n"}
        ] do
      assert {:error, :invalid_request} =
               Passkeys.begin_registration(c.pair.access_jwt, @password, browser, name)
    end

    assert Repo.aggregate(PasskeyChallenge, :count) == 0
  end

  test "challenges bind browser, purpose, session, expiry and ceremony", c do
    {request, fixture} = begin(c)
    response = Fixture.registration(fixture)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               random(),
               request.reference,
               response
             )

    assert Repo.aggregate(PasskeyChallenge, :count) == 1

    assert {:error, :invalid_passkey} =
             Passkeys.complete_login(c.browser, request.reference, Fixture.assertion(fixture))

    assert Repo.aggregate(PasskeyChallenge, :count) == 1
    {:ok, other} = Sessions.create(c.did, @password)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               other.access_jwt,
               c.browser,
               request.reference,
               response
             )

    assert Repo.aggregate(PasskeyChallenge, :count) == 0
    {request, fixture} = begin(c)
    Repo.update_all(PasskeyChallenge, set: [expires_at: 1])

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture)
             )

    {request, fixture} = begin(c)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture, client: %{origin: "https://evil.example.com"})
             )

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture)
             )

    assert Repo.aggregate(Passkey, :count) == 0
  end

  test "password replacement or source-session revocation invalidates pending enrollment", c do
    {request, fixture} = begin(c)
    {:ok, replacement} = Credentials.hash("changed account password")

    Repo.get!(Atoll.Accounts.Credential, c.did)
    |> Ecto.Changeset.change(password_hash: replacement)
    |> Repo.update!()

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture)
             )

    {:ok, _} =
      Passkeys.begin_registration(c.pair.access_jwt, "changed account password", c.browser, "Key")

    assert Repo.aggregate(PasskeyChallenge, :count) == 1
    assert {:ok, _} = Sessions.revoke(c.pair.refresh_jwt)
    assert Repo.aggregate(PasskeyChallenge, :count) == 0
  end

  test "a credential cannot be registered twice and user handles remain stable", c do
    {credential, fixture} = enroll(c)
    {request, next} = begin(c)
    assert next.stored.user_handle == fixture.stored.user_handle

    assert request.public_key.excludeCredentials == [
             %{type: "public-key", id: base(fixture.stored.credential_id)}
           ]

    next = %{fixture | context: next.context}

    assert {:error, :passkey_already_registered} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(next)
             )

    assert Repo.aggregate(Passkey, :count) == 1
    assert Repo.aggregate(PasskeyChallenge, :count) == 0
    assert {:ok, :revoked} = Passkeys.revoke(c.pair.access_jwt, @password, credential.id)
    {_request, third} = begin(c)
    assert third.stored.user_handle == fixture.stored.user_handle
  end

  test "bad proofs are consumed and counters cannot go backwards", c do
    {credential, fixture} = enroll(c)

    for count <- [2, 1] do
      {:ok, request} = Passkeys.begin_login(c.browser)
      current = %{fixture | context: Fixture.context(request.public_key)}

      result =
        Passkeys.complete_login(
          c.browser,
          request.reference,
          Fixture.assertion(current, count: count)
        )

      if count == 2,
        do: assert({:ok, _} = result),
        else: assert(result == {:error, :invalid_passkey})

      assert Repo.aggregate(PasskeyChallenge, :count) == 0
    end

    assert Repo.get!(Passkey, credential.id).sign_count == 2
    {:ok, request} = Passkeys.begin_login(c.browser)

    invalid = %{
      fixture
      | context: Fixture.context(request.public_key),
        private: elem(:crypto.generate_key(:ecdh, :secp256r1), 1)
    }

    assert {:error, :invalid_passkey} =
             Passkeys.complete_login(
               c.browser,
               request.reference,
               Fixture.assertion(invalid, count: 3)
             )

    assert Repo.aggregate(PasskeyChallenge, :count) == 0
    assert Repo.get!(Passkey, credential.id).sign_count == 2
  end

  test "proof consumption survives session issuance failure", c do
    {_, fixture} = enroll(c)
    Application.put_env(:atoll, :session_max_count, 1)
    {:ok, request} = Passkeys.begin_login(c.browser)
    response = Fixture.assertion(%{fixture | context: Fixture.context(request.public_key)})

    assert {:error, :session_limit_exceeded} =
             Passkeys.complete_login(c.browser, request.reference, response)

    assert Repo.aggregate(PasskeyChallenge, :count) == 0
    Application.put_env(:atoll, :session_max_count, 100)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_login(c.browser, request.reference, response)
  end

  test "enabled TOTP protects enrollment and removal; passkey login supplies user verification",
       c do
    {:ok, setup} = Authenticator.begin(c.pair.access_jwt, @password)

    {:ok, code} =
      TOTP.code(Base.decode32!(setup.secret, padding: false), System.system_time(:second))

    {:ok, %{recovery_codes: [first, second | _]}} = Authenticator.confirm(c.pair.access_jwt, code)

    assert {:error, :totp_required} =
             Passkeys.begin_registration(c.pair.access_jwt, @password, c.browser, "Key")

    {:ok, request} =
      Passkeys.begin_registration(c.pair.access_jwt, @password, c.browser, "Key",
        totp_code: first
      )

    fixture = Fixture.new(request.public_key)

    {:ok, key} =
      Passkeys.complete_registration(
        c.pair.access_jwt,
        c.browser,
        request.reference,
        Fixture.registration(fixture)
      )

    {:ok, request} = Passkeys.begin_login(c.browser)

    assert {:ok, _} =
             Passkeys.complete_login(
               c.browser,
               request.reference,
               Fixture.assertion(%{fixture | context: Fixture.context(request.public_key)})
             )

    assert {:error, :totp_required} = Passkeys.revoke(c.pair.access_jwt, @password, key.id)

    assert {:ok, :revoked} =
             Passkeys.revoke(c.pair.access_jwt, @password, key.id, totp_code: second)
  end

  test "factor enrollment after passkey setup began invalidates its approval", c do
    {request, fixture} = begin(c)
    {:ok, setup} = Authenticator.begin(c.pair.access_jwt, @password)

    {:ok, code} =
      TOTP.code(Base.decode32!(setup.secret, padding: false), System.system_time(:second))

    {:ok, _} = Authenticator.confirm(c.pair.access_jwt, code)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture)
             )
  end

  test "disabling ceremonies retains owner inventory and recovery through password", c do
    {key, _} = enroll(c)
    Application.put_env(:atoll, :passkeys_enabled, false)
    assert {:error, :passkeys_disabled} = Passkeys.begin_login(c.browser)

    assert {:error, :passkeys_disabled} =
             Passkeys.begin_registration(c.pair.access_jwt, @password, c.browser, "Key")

    assert {:ok, [_]} = Passkeys.list(c.pair.access_jwt)
    assert {:ok, :revoked} = Passkeys.revoke(c.pair.access_jwt, @password, key.id)
    assert {:ok, _} = Sessions.create(c.did, @password)
  end

  test "owner isolation and inactive accounts cannot use or remove passkeys", c do
    {key, fixture} = enroll(c)
    other = "did:plc:otherpasskeyowner"
    {:ok, _} = Atoll.Repositories.create(other, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(other, @password)
    {:ok, pair} = Sessions.create(other, @password)
    assert {:ok, []} = Passkeys.list(pair.access_jwt)
    assert {:ok, :revoked} = Passkeys.revoke(pair.access_jwt, @password, key.id)
    assert Repo.get!(Passkey, key.id)
    {:ok, request} = Passkeys.begin_login(c.browser)
    assert {:ok, _} = Atoll.Repositories.set_status(c.did, :deactivated)

    assert {:error, :invalid_passkey} =
             Passkeys.complete_login(
               c.browser,
               request.reference,
               Fixture.assertion(%{fixture | context: Fixture.context(request.public_key)})
             )
  end

  test "challenge capacity and bounded reclamation, account key cap, and transaction boundary",
       c do
    {:ok, _} = Passkeys.begin_login(c.browser)
    template = Repo.one!(PasskeyChallenge) |> Map.from_struct() |> Map.delete(:__meta__)
    rows = for _ <- 1..9999, do: %{template | digest: :crypto.strong_rand_bytes(32)}
    Enum.each(Enum.chunk_every(rows, 1000), &Repo.insert_all(PasskeyChallenge, &1, log: false))
    assert {:error, :passkey_challenge_capacity} = Passkeys.begin_login(c.browser)
    Repo.update_all(PasskeyChallenge, set: [expires_at: 1])
    assert {:ok, _} = Passkeys.begin_login(c.browser)
    assert Repo.aggregate(PasskeyChallenge, :count) == 9001
    {key, _} = enroll(c)
    template = Repo.get!(Passkey, key.id) |> Map.from_struct() |> Map.delete(:__meta__)

    rows =
      for _ <- 1..9,
          do: %{template | id: Ecto.UUID.generate(), credential_id: :crypto.strong_rand_bytes(32)}

    Repo.insert_all(Passkey, rows, log: false)

    assert {:error, :passkey_limit} =
             Passkeys.begin_registration(c.pair.access_jwt, @password, c.browser, "Key")

    assert {:ok, {:error, :passkey_inside_transaction}} =
             Repo.transaction(fn -> Passkeys.begin_login(c.browser) end)
  end

  test "operator credential revocation removes passkeys and account deletion cascades their data",
       c do
    {_, _} = enroll(c)
    Repo.insert!(%Atoll.Accounts.Profile{did: c.did, handle: "passkey.example.com"})
    {:ok, _} = Repo.transaction(fn -> Atoll.Accounts.CredentialRevocation.revoke!(c.did) end)
    assert Repo.aggregate(Passkey, :count) == 0
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(PasskeyUser, :count) == 1
    Repo.get!(Atoll.Repositories.Head, c.did) |> Repo.delete!()
    assert Repo.aggregate(PasskeyUser, :count) == 0
  end

  defp begin(c) do
    {:ok, request} =
      Passkeys.begin_registration(c.pair.access_jwt, @password, c.browser, "Laptop")

    assert request.public_key.authenticatorSelection.residentKey == "required"
    {request, Fixture.new(request.public_key)}
  end

  defp enroll(c) do
    {request, fixture} = begin(c)

    assert {:ok, key} =
             Passkeys.complete_registration(
               c.pair.access_jwt,
               c.browser,
               request.reference,
               Fixture.registration(fixture)
             )

    {key, fixture}
  end

  defp base(value), do: Base.url_encode64(value, padding: false)
  defp random, do: base(:crypto.strong_rand_bytes(32))
end
