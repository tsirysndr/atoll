defmodule Atoll.Accounts.LoginIdentifierTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.{Credentials, LoginIdentifier}

  @password "login identifier password"

  setup do
    did = "did:plc:loginidentifier"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, @password)

    Atoll.Repo.insert!(%Atoll.Accounts.Profile{did: did, handle: "alice.example.com"})

    signing = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case signing do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    # Resolution that reaches the network must never be required for a local
    # account, so point it where nothing answers.
    previous = Application.fetch_env(:atoll, :identity_resolution_options)

    Application.put_env(:atoll, :identity_resolution_options,
      dns: fn _ -> {:error, :nxdomain} end,
      http: fn _, _ -> {:error, :econnrefused} end
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :identity_resolution_options, value)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end
    end)

    %{did: did}
  end

  test "resolves a hosted handle from its own records", %{did: did} do
    assert {:ok, ^did, "alice.example.com"} = LoginIdentifier.resolve("alice.example.com")
  end

  test "accepts stray whitespace and capitals around a handle", %{did: did} do
    assert {:ok, ^did, "alice.example.com"} = LoginIdentifier.resolve("  Alice.Example.com ")
  end

  test "passes a DID through untouched", %{did: did} do
    assert {:ok, ^did, nil} = LoginIdentifier.resolve(did)
    assert {:ok, ^did, nil} = LoginIdentifier.resolve(" #{did} ")
  end

  test "signs in with a handle while handle resolution is unreachable", %{did: did} do
    assert {:ok, pair, "alice.example.com"} =
             LoginIdentifier.create_session("alice.example.com", @password)

    assert pair.did == did
  end

  test "refuses an unknown handle", _ do
    assert {:error, :invalid_credentials} = LoginIdentifier.resolve("nobody.example.com")
  end
end
