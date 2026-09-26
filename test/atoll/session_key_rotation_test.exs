defmodule Atoll.SessionKeyRotationTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{Credentials, Sessions, Tokens}
  alias Atoll.{Repositories, SigningKey}
  @did "did:web:session-rotation.example.com"

  setup do
    prior =
      Map.new(
        [:session_signing_key, :previous_session_signing_keys],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    old = :crypto.strong_rand_bytes(32)
    new = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :session_signing_key, old)
    Application.put_env(:atoll, :previous_session_signing_keys, [])

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, "session rotation password")
    {:ok, pair} = Sessions.create(@did, "session rotation password")
    %{old: old, new: new, pair: pair}
  end

  test "old sessions survive overlap and refreshing migrates tokens to the active key", c do
    rotate(c)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, refreshed} = Sessions.refresh(c.pair.refresh_jwt)
    assert {:error, :invalid_token} = Sessions.refresh(c.pair.refresh_jwt)

    for {token, kind} <- [{refreshed.access_jwt, :access}, {refreshed.refresh_jwt, :refresh}] do
      assert {:ok, _} = Tokens.verify(token, kind, secret: c.new)
      assert {:error, :invalid_token} = Tokens.verify(token, kind, secret: c.old)
    end

    Application.put_env(:atoll, :previous_session_signing_keys, [])
    assert {:error, :invalid_token} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, _} = Sessions.authenticate(refreshed.access_jwt)
    assert {:ok, _} = Sessions.refresh(refreshed.refresh_jwt)
  end

  test "overlap preserves type, scope, audience, expiry and persistent revocation checks", c do
    rotate(c)
    assert {:error, :invalid_token} = Tokens.verify(c.pair.access_jwt, :refresh)
    assert {:error, :invalid_token} = Tokens.verify(c.pair.refresh_jwt, :access)

    assert {:error, :invalid_token} =
             Tokens.verify(c.pair.access_jwt, :access, audience: "did:web:other.example.com")

    assert {:ok, claims} = Tokens.verify(c.pair.access_jwt, :access)

    assert {:error, :expired_token} =
             Tokens.verify(c.pair.access_jwt, :access, now: claims["exp"])

    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert {:error, :invalid_token} = Sessions.authenticate(c.pair.access_jwt)
    assert {:error, :invalid_token} = Sessions.refresh(c.pair.refresh_jwt)
  end

  test "new login tokens use only the active key, while fallback keys remain verification-only",
       c do
    rotate(c)
    {:ok, pair} = Sessions.create(@did, "session rotation password")
    assert {:ok, _} = Tokens.verify(pair.access_jwt, :access, secret: c.new)
    assert {:error, :invalid_token} = Tokens.verify(pair.access_jwt, :access, secret: c.old)
    # A trusted custom issuer does not implicitly inherit the runtime fallback ring.
    assert {:error, :invalid_token} = Tokens.verify(c.pair.access_jwt, :access, secret: c.new)

    assert {:ok, _} =
             Tokens.verify(c.pair.access_jwt, :access, secret: c.new, previous_secrets: [c.old])
  end

  test "bounded key configuration rejects malformed values and does not rescue a missing active key",
       c do
    assert Tokens.previous_from_env!(nil) == []
    assert Tokens.previous_from_env!(Base.encode64(c.old)) == [c.old]

    for value <- [
          "bad",
          Base.encode64(<<1>>),
          Enum.join(List.duplicate(Base.encode64(c.old), 5), ",")
        ] do
      assert_raise ArgumentError, fn -> Tokens.previous_from_env!(value) end
    end

    for keys <- [nil, [<<1>>], List.duplicate(c.old, 5)] do
      assert {:error, :session_configuration_missing} =
               Tokens.verify(c.pair.access_jwt, :access, previous_secrets: keys)
    end

    rotate(c)
    Application.delete_env(:atoll, :session_signing_key)
    assert {:error, :session_configuration_missing} = Tokens.verify(c.pair.access_jwt, :access)
  end

  defp rotate(c) do
    Application.put_env(:atoll, :session_signing_key, c.new)
    Application.put_env(:atoll, :previous_session_signing_keys, [c.old])
  end
end
