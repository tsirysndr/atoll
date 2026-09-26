defmodule Atoll.OAuth.KeyChecksTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{KeyChecks, Session, AccessToken, RefreshUse}
  @client "https://app.example.com/metadata.json"

  setup do
    did = "did:plc:keychecks"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())

    source =
      Repo.insert!(%Atoll.Accounts.Session{
        id: random(),
        did: did,
        refresh_hash: :crypto.strong_rand_bytes(32),
        expires_at: System.system_time(:second) + 3600
      })

    {_, public} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()
    public = Map.put(public, "kid", "client-key")

    binding = %{
      "kid" => "client-key",
      "alg" => "ES256",
      "jkt" => JOSE.JWK.from_map(public) |> JOSE.JWK.thumbprint()
    }

    %{did: did, source: source, public: public, binding: binding}
  end

  test "fresh retained key keeps sessions; removal cascades to access tokens and replay markers",
       c do
    session = insert_session(c)

    Repo.insert!(%AccessToken{
      digest: :crypto.strong_rand_bytes(32),
      session_id: session.id,
      scope: "atproto",
      expires_at: session.expires_at
    })

    Repo.insert!(%RefreshUse{
      digest: :crypto.strong_rand_bytes(32),
      session_id: session.id,
      expires_at: session.expires_at
    })

    assert {:ok, %{checked: 1, revoked: 0, failed: 0}} = KeyChecks.run(nil, transport([c.public]))
    assert Repo.get(Session, session.id)
    assert {:ok, %{checked: 1, revoked: 1}} = KeyChecks.run(nil, transport([]))
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
    assert Repo.aggregate(RefreshUse, :count) == 0
    assert {:ok, :done} = KeyChecks.run(nil, transport([]))
  end

  test "replacement under the same kid revokes; another advertised key cannot preserve a session",
       c do
    insert_session(c)
    {_, replacement} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()

    assert {:ok, %{revoked: 1}} =
             KeyChecks.run(nil, transport([Map.put(replacement, "kid", "client-key")]))

    insert_session(c)

    assert {:ok, %{revoked: 1}} =
             KeyChecks.run(nil, transport([Map.put(c.public, "kid", "other-key")]))
  end

  test "network or malformed metadata failure advances without revocation", c do
    session = insert_session(c)

    for opts <- [
          Keyword.put(transport([]), :lookup, fn _ -> {:error, :nxdomain} end),
          transport([%{"kid" => "client-key", "kty" => "oct", "k" => "private"}])
        ] do
      assert {:ok, %{cursor: cursor, checked: 0, revoked: 0, failed: 1}} =
               KeyChecks.run(nil, opts)

      assert cursor == {@client, session.id}
      assert Repo.get(Session, session.id)
      assert {:ok, :done} = KeyChecks.run(cursor, opts)
    end
  end

  test "public and expired sessions are skipped and reads cannot wrap network work in a transaction",
       c do
    insert_session(c, %{client_binding: nil})
    insert_session(c, %{expires_at: 1})
    assert {:ok, :done} = KeyChecks.run(nil, transport([]))
    assert Repo.aggregate(Session, :count) == 2

    assert {:ok, {:error, :oauth_key_checks_inside_transaction}} =
             Repo.transaction(fn -> KeyChecks.run() end)
  end

  test "batches bound both sessions and fetched clients, then advance after deleted rows", c do
    for _ <- 1..101, do: insert_session(c)
    second = "https://z.example.com/metadata.json"
    insert_session(c, %{client_id: second})

    assert {:ok, %{cursor: cursor, checked: 100, revoked: 100}} =
             KeyChecks.run(nil, transport([]))

    assert {:ok, %{cursor: last, checked: 1, revoked: 1}} = KeyChecks.run(cursor, transport([]))

    assert {:ok, %{cursor: {^second, _} = last_client, checked: 1, revoked: 1}} =
             KeyChecks.run(last, transport([], second))

    assert {:ok, :done} = KeyChecks.run(last_client, transport([]))
  end

  test "changed and newly created bindings during fetch are not revoked by an older snapshot",
       c do
    prior = insert_session(c)

    opts =
      transport([], @client, fn ->
        Repo.get!(Session, prior.id)
        |> Ecto.Changeset.change(client_binding: Map.put(c.binding, "kid", "new-key"))
        |> Repo.update!()

        insert_session(c)
      end)

    assert {:ok, %{checked: 1, revoked: 0}} = KeyChecks.run(nil, opts)
    assert Repo.aggregate(Session, :count) == 2
    assert {:ok, %{revoked: 2}} = KeyChecks.run(nil, transport([]))
  end

  test "refresh rotation during fetch does not hide removal and deletion during fetch is harmless",
       c do
    session = insert_session(c)

    opts =
      transport([], @client, fn ->
        Repo.get!(Session, session.id)
        |> Ecto.Changeset.change(refresh_digest: :crypto.strong_rand_bytes(32))
        |> Repo.update!()
      end)

    assert {:ok, %{revoked: 1}} = KeyChecks.run(nil, opts)
    insert_session(c)
    opts = transport([], @client, fn -> Repo.delete_all(Atoll.Accounts.Session) end)
    assert {:ok, %{checked: 1, revoked: 0}} = KeyChecks.run(nil, opts)
  end

  defp insert_session(c, changes \\ %{}) do
    struct!(
      Session,
      Map.merge(
        %{
          id: random(),
          did: c.did,
          source_session_id: c.source.id,
          issuer: "https://pds.example.com",
          client_id: @client,
          scope: "atproto",
          dpop_jkt: random(),
          client_binding: c.binding,
          refresh_digest: :crypto.strong_rand_bytes(32),
          expires_at: c.source.expires_at
        },
        changes
      )
    )
    |> Repo.insert!()
  end

  defp transport(keys, client \\ @client, before_reply \\ fn -> :ok end) do
    [
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            before_reply.()

            Req.Test.json(conn, %{
              "client_id" => client,
              "grant_types" => ["authorization_code", "refresh_token"],
              "response_types" => ["code"],
              "scope" => "atproto",
              "redirect_uris" => ["https://app.example.com/callback"],
              "dpop_bound_access_tokens" => true,
              "token_endpoint_auth_method" => "private_key_jwt",
              "jwks" => %{"keys" => keys}
            })
          end
        )
    ]
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
