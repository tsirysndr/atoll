defmodule Atoll.Accounts.WebAuthnTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.WebAuthn
  alias Atoll.Accounts.WebAuthn.CBOR
  alias Atoll.CBOR.Bytes

  setup do
    {:ok, context} = WebAuthn.challenge("https://pds.example.com")
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    id = :crypto.strong_rand_bytes(32)
    user = :crypto.strong_rand_bytes(32)

    stored = %{
      credential_id: id,
      public_key: public,
      user_handle: user,
      sign_count: 0,
      backup_eligible: false
    }

    %{context: context, stored: stored, private: private}
  end

  test "origin generation is canonical, exact-host and HTTPS except localhost" do
    for origin <- [
          "https://pds.example.com",
          "https://pds.example.com:8443",
          "http://localhost:4000"
        ] do
      assert {:ok, first} = WebAuthn.challenge(origin)
      assert byte_size(first.challenge) == 32
      assert first.origin == origin
      assert first.rp_id == URI.parse(origin).host
      {:ok, second} = WebAuthn.challenge(origin)
      refute first.challenge == second.challenge
    end

    for origin <- [
          "http://pds.example.com",
          "https://pds.example.com/",
          "https://pds.example.com:443",
          "https://pds.example.com?q=1",
          "https://user@pds.example.com",
          "https://pds.example.com#x",
          "https://127.0.0.1",
          "javascript:x",
          nil
        ] do
      assert {:error, :invalid_webauthn_origin} = WebAuthn.challenge(origin)
    end
  end

  test "Chrome's real WebAuthn serialization verifies for registration and assertion" do
    fixture =
      File.read!(Path.expand("../fixtures/webauthn_chrome.json", __DIR__)) |> Jason.decode!()

    {:ok, ctx} = WebAuthn.challenge(fixture["origin"])
    registration = %{ctx | challenge: unbase(fixture["registrationChallenge"])}
    assert {:ok, stored} = WebAuthn.register(fixture["registration"], registration)
    stored = Map.put(stored, :user_handle, unbase(fixture["userHandle"]))
    authentication = %{ctx | challenge: unbase(fixture["loginChallenge"])}

    assert {:ok, %{sign_count: count}} =
             WebAuthn.authenticate(fixture["assertion"], authentication, stored)

    assert count > stored.sign_count

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(fixture["assertion"], authentication, %{
               stored
               | sign_count: count
             })
  end

  test "none registration stores a validated P-256 public key and no private material", c do
    assert {:ok, result} = WebAuthn.register(registration(c), c.context)
    assert result.public_key == c.stored.public_key
    assert result.credential_id == c.stored.credential_id
    assert result.sign_count == 0
    refute result.backup_eligible
    assert map_size(result) == 6
  end

  test "client data binds ceremony type, random challenge and exact origin", c do
    for fields <- [
          %{type: "webauthn.get"},
          %{challenge: base(:crypto.strong_rand_bytes(32))},
          %{origin: "https://evil.example.com"},
          %{origin: "https://pds.example.com.evil.test"},
          %{crossOrigin: true},
          %{crossOrigin: nil},
          %{topOrigin: "https://pds.example.com"}
        ] do
      assert {:error, :invalid_webauthn} =
               WebAuthn.register(registration(c, client: fields), c.context)
    end

    response = registration(c)
    raw = unbase(response["response"]["clientDataJSON"])
    duplicate = String.replace_suffix(raw, "}", ",\"origin\":\"https://pds.example.com\"}")

    assert {:error, :invalid_webauthn} =
             WebAuthn.register(
               put_in(response, ["response", "clientDataJSON"], base(duplicate)),
               c.context
             )
  end

  test "registration requires presence, verification, RP binding, matching ID and none attestation",
       c do
    for opts <- [
          [flags: 64],
          [flags: 65],
          [flags: 68],
          [flags: 85],
          [rp_id: "evil.example.com"],
          [fmt: "packed"],
          [statement: %{"sig" => %Bytes{data: "bad"}}],
          [credential_id: "other"]
        ] do
      assert {:error, :invalid_webauthn} = WebAuthn.register(registration(c, opts), c.context)
    end

    response = registration(c)

    assert {:error, :invalid_webauthn} =
             WebAuthn.register(%{response | "rawId" => base("other")}, c.context)

    assert {:error, :invalid_webauthn} =
             WebAuthn.register(%{response | "type" => "password"}, c.context)
  end

  test "registration rejects off-curve keys and unsupported algorithms", c do
    off_curve = %{c | stored: %{c.stored | public_key: <<4, 0::512>>}}
    assert {:error, :invalid_webauthn} = WebAuthn.register(registration(off_curve), c.context)

    assert {:error, :invalid_webauthn} =
             WebAuthn.register(registration(c, cose: <<0xA1, 1, 1>>), c.context)
  end

  test "assertions verify the original bytes, user handle, credential and algorithm signature",
       c do
    good = assertion(c)

    assert {:ok, %{sign_count: 1, backup_state: false}} =
             WebAuthn.authenticate(good, c.context, c.stored)

    for {field, bad} <- [
          {"signature", base(<<1, 2, 3>>)},
          {"signature", base(:crypto.strong_rand_bytes(72))},
          {"userHandle", base(:crypto.strong_rand_bytes(32))},
          {"userHandle", nil},
          {"authenticatorData", base("bad")}
        ] do
      assert {:error, :invalid_webauthn} =
               WebAuthn.authenticate(put_in(good, ["response", field], bad), c.context, c.stored)
    end

    altered =
      put_in(
        good,
        ["response", "clientDataJSON"],
        base(client(c.context, "webauthn.get", %{extra: "not signed"}))
      )

    assert {:error, :invalid_webauthn} = WebAuthn.authenticate(altered, c.context, c.stored)

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(good, c.context, %{c.stored | credential_id: "other"})

    {wrong_key, _} = :crypto.generate_key(:ecdh, :secp256r1)

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(good, c.context, %{c.stored | public_key: wrong_key})
  end

  test "signed assertions must still satisfy origin, flags and counter rules", c do
    for opts <- [
          [flags: 1],
          [flags: 4],
          [flags: 69],
          [flags: 21],
          [rp_id: "evil.example.com"],
          [client: %{crossOrigin: true}],
          [client: %{type: "webauthn.create"}],
          [client: %{challenge: "other"}]
        ] do
      assert {:error, :invalid_webauthn} =
               WebAuthn.authenticate(assertion(c, opts), c.context, c.stored)
    end

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(assertion(c, count: 4), c.context, %{c.stored | sign_count: 4})

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(assertion(c, count: 0), c.context, %{c.stored | sign_count: 4})

    assert {:ok, _} = WebAuthn.authenticate(assertion(c, count: 0), c.context, c.stored)
  end

  test "synced credentials preserve backup eligibility and update backup state", c do
    assert {:ok, %{backup_eligible: true, backup_state: true}} =
             WebAuthn.register(registration(c, flags: 93), c.context)

    synced = %{c.stored | backup_eligible: true}

    assert {:ok, %{backup_state: true}} =
             WebAuthn.authenticate(assertion(c, flags: 29, count: 0), c.context, synced)

    assert {:ok, %{backup_state: false}} =
             WebAuthn.authenticate(assertion(c, flags: 13, count: 0), c.context, synced)

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(assertion(c, flags: 5), c.context, synced)

    assert {:error, :invalid_webauthn} =
             WebAuthn.authenticate(assertion(c, flags: 13), c.context, c.stored)
  end

  test "authenticator extensions must be a complete bounded map with text keys", c do
    extension = Atoll.CBOR.encode!(%{"credProtect" => 2})
    assert {:ok, _} = WebAuthn.register(registration(c, flags: 197, tail: extension), c.context)

    assert {:ok, _} =
             WebAuthn.authenticate(assertion(c, flags: 133, tail: extension), c.context, c.stored)

    for {flags, tail} <- [{5, extension}, {133, <<>>}, {133, <<0xA0, 0>>}, {133, <<0xA1, 1, 1>>}] do
      assert {:error, :invalid_webauthn} =
               WebAuthn.authenticate(assertion(c, flags: flags, tail: tail), c.context, c.stored)
    end
  end

  test "CBOR distinguishes bytes, accepts unordered maps, and rejects duplicate or dangerous containers" do
    assert {:ok, %{"z" => 1, "a" => %Bytes{data: "x"}}} =
             CBOR.decode(<<0xA2, 0x61, ?z, 1, 0x61, ?a, 0x41, ?x>>)

    assert {:ok, %{1 => -7}} = CBOR.decode(<<0xA1, 1, 0x26>>)

    for bytes <- [
          <<0xA2, 1, 2, 1, 3>>,
          <<0xA2, 1, 2, 0x18, 1, 3>>,
          <<0xBF, 0xFF>>,
          <<0xC0, 0>>,
          <<0xFB, 0::64>>,
          <<0x61, 255>>,
          <<0x5B, 0xFFFFFFFFFFFFFFFF::64>>,
          <<0x99, 256::16>>,
          :binary.copy(<<0x81>>, 10) <> <<0>>,
          <<0xA0, 0>>,
          :binary.copy(<<0>>, 16_385)
        ] do
      assert {:error, :invalid_webauthn} = CBOR.decode(bytes)
    end
  end

  test "bounded wire inputs and malformed contexts fail closed", c do
    good = registration(c)

    for raw <- [
          nil,
          [],
          "",
          "=",
          String.duplicate("A", 30_000),
          base("not JSON"),
          base(String.duplicate("x", 4097))
        ] do
      assert {:error, :invalid_webauthn} =
               WebAuthn.register(put_in(good, ["response", "clientDataJSON"], raw), c.context)
    end

    assert {:error, :invalid_webauthn} = WebAuthn.register(good, %{})
    assert {:error, :invalid_webauthn} = WebAuthn.authenticate(%{}, c.context, c.stored)
  end

  defp registration(c, opts \\ []) do
    <<4, x::binary-size(32), y::binary-size(32)>> = c.stored.public_key

    cose =
      Keyword.get(
        opts,
        :cose,
        <<0xA5, 1, 2, 3, 0x26, 0x20, 1, 0x21, 0x58, 32, x::binary, 0x22, 0x58, 32, y::binary>>
      )

    id = Keyword.get(opts, :credential_id, c.stored.credential_id)

    data =
      auth_data(c, Keyword.put_new(opts, :flags, 69)) <>
        <<0::128, byte_size(id)::16, id::binary, cose::binary>> <> Keyword.get(opts, :tail, "")

    object =
      Atoll.CBOR.encode!(%{
        "fmt" => Keyword.get(opts, :fmt, "none"),
        "attStmt" => Keyword.get(opts, :statement, %{}),
        "authData" => %Bytes{data: data}
      })

    envelope(c, %{
      "attestationObject" => base(object),
      "clientDataJSON" =>
        base(client(c.context, "webauthn.create", Keyword.get(opts, :client, %{})))
    })
  end

  defp assertion(c, opts \\ []) do
    data = auth_data(c, Keyword.put_new(opts, :count, 1)) <> Keyword.get(opts, :tail, "")
    raw = client(c.context, "webauthn.get", Keyword.get(opts, :client, %{}))

    signature =
      :crypto.sign(:ecdsa, :sha256, data <> :crypto.hash(:sha256, raw), [c.private, :secp256r1])

    envelope(c, %{
      "authenticatorData" => base(data),
      "signature" => base(signature),
      "clientDataJSON" => base(raw),
      "userHandle" => base(c.stored.user_handle)
    })
  end

  defp auth_data(c, opts),
    do:
      :crypto.hash(:sha256, Keyword.get(opts, :rp_id, c.context.rp_id)) <>
        <<Keyword.get(opts, :flags, 5), Keyword.get(opts, :count, 0)::32>>

  defp client(ctx, type, extra),
    do:
      Map.merge(
        %{type: type, challenge: base(ctx.challenge), origin: ctx.origin, crossOrigin: false},
        extra
      )
      |> Jason.encode!()

  defp envelope(c, payload),
    do: %{
      "id" => base(c.stored.credential_id),
      "rawId" => base(c.stored.credential_id),
      "type" => "public-key",
      "response" => payload
    }

  defp base(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unbase(bytes), do: Base.url_decode64!(bytes, padding: false)
end
