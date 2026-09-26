defmodule Atoll.OAuth.SessionManagementTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{SessionManagement, Session, AccessToken, RefreshUse}
  alias Atoll.Accounts.{Sessions, Tokens}

  setup do
    did = "did:plc:sessionmanagement"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    opts = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, pair} = Sessions.create_for_account(did, opts)
    {:ok, claims} = Tokens.verify(pair.access_jwt, :access, opts)
    %{did: did, pair: pair, opts: opts, source: claims["sid"]}
  end

  test "inventory is paginated, owner-scoped, live and contains no token/key material", c do
    sessions = for _ <- 1..3, do: insert_session(c)
    insert_session(c, %{expires_at: 1})
    other = other_account(c)
    insert_session(other)
    {:ok, first} = SessionManagement.list(c.pair.access_jwt, 2, nil, c.opts)
    assert length(first.sessions) == 2
    assert first.cursor == List.last(first.sessions).id
    {:ok, last} = SessionManagement.list(c.pair.access_jwt, 2, first.cursor, c.opts)
    refute Map.has_key?(last, :cursor)

    assert Enum.sort(Enum.map(first.sessions ++ last.sessions, & &1.id)) ==
             Enum.sort(Enum.map(sessions, & &1.id))

    for entry <- first.sessions ++ last.sessions do
      assert Enum.sort(Map.keys(entry)) == [:clientId, :expiresAt, :id, :refreshable, :scope]
      assert entry.clientId == "https://client.example.com/metadata.json"
      assert entry.refreshable
    end

    assert {:ok, %{sessions: []}} =
             SessionManagement.list(c.pair.access_jwt, 2, List.last(last.sessions).id, c.opts)
  end

  test "revocation cascades to access tokens and used refresh markers without deleting account sessions",
       c do
    session = insert_session(c)
    keep = insert_session(c)

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

    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, session.id, c.opts)
    assert Repo.get(Session, session.id) == nil
    assert Repo.get(Session, keep.id)
    assert Repo.aggregate(AccessToken, :count) == 0
    assert Repo.aggregate(RefreshUse, :count) == 0
    assert Repo.get(Atoll.Accounts.Session, c.source)
    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, session.id, c.opts)
  end

  test "foreign and unknown IDs are indistinguishable and cannot revoke another owner", c do
    foreign = insert_session(other_account(c))
    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, foreign.id, c.opts)
    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, random(), c.opts)
    assert Repo.get(Session, foreign.id)
  end

  test "revoked and expired management sessions cannot list or revoke grants", c do
    session = insert_session(c)
    source = Repo.get!(Atoll.Accounts.Session, c.source)
    source |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :expired_token} = SessionManagement.list(c.pair.access_jwt, 50, nil, c.opts)

    assert {:error, :expired_token} =
             SessionManagement.revoke(c.pair.access_jwt, session.id, c.opts)

    Repo.delete!(Repo.get!(Atoll.Accounts.Session, c.source))
    assert {:error, :invalid_token} = SessionManagement.list(c.pair.access_jwt, 50, nil, c.opts)
  end

  test "app passwords, refresh tokens and opaque OAuth tokens cannot manage grants", c do
    session = insert_session(c)

    for scope <- ["com.atproto.appPass", "com.atproto.appPassPrivileged"] do
      app =
        Repo.insert!(%Atoll.Accounts.AppPassword{
          did: c.did,
          name: scope,
          digest: :crypto.strong_rand_bytes(32),
          privileged: scope == "com.atproto.appPassPrivileged"
        })

      {:ok, restricted} =
        Sessions.create_for_account(
          c.did,
          Keyword.merge(c.opts, access_scope: scope, app_password_id: app.id)
        )

      # Scope is signed as well as persisted; this is a real restricted session.
      assert {:error, :forbidden} = SessionManagement.list(restricted.access_jwt, 50, nil, c.opts)

      assert {:error, :forbidden} =
               SessionManagement.revoke(restricted.access_jwt, session.id, c.opts)
    end

    for token <- [c.pair.refresh_jwt, "atoll_access_" <> random()] do
      assert {:error, :invalid_token} = SessionManagement.list(token, 50, nil, c.opts)
      assert {:error, :invalid_token} = SessionManagement.revoke(token, session.id, c.opts)
    end

    assert Repo.get(Session, session.id)
  end

  test "deactivated owners can revoke and inventories omit expired grant sources", c do
    session = insert_session(c)
    {:ok, second} = Sessions.create_for_account(c.did, c.opts)
    {:ok, claims} = Tokens.verify(second.access_jwt, :access, c.opts)
    hidden = insert_session(%{c | source: claims["sid"]})

    Repo.get!(Atoll.Accounts.Session, claims["sid"])
    |> Ecto.Changeset.change(expires_at: 1)
    |> Repo.update!()

    {:ok, _} = Atoll.Repositories.set_status(c.did, :deactivated)

    assert {:ok, %{sessions: [%{id: id}]}} =
             SessionManagement.list(c.pair.access_jwt, 50, nil, c.opts)

    assert id == session.id
    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, hidden.id, c.opts)
    assert {:ok, :ok} = SessionManagement.revoke(c.pair.access_jwt, id, c.opts)
  end

  test "invalid page bounds and identifiers are rejected", c do
    for limit <- [0, 101, "10", nil],
        do:
          assert(
            {:error, :invalid_request} =
              SessionManagement.list(c.pair.access_jwt, limit, nil, c.opts)
          )

    for id <- ["", "bad", %{}, String.duplicate("x", 2048)] do
      assert {:error, :invalid_request} =
               SessionManagement.list(c.pair.access_jwt, 50, id, c.opts)

      assert {:error, :invalid_request} = SessionManagement.revoke(c.pair.access_jwt, id, c.opts)
    end
  end

  defp insert_session(c, changes \\ %{}) do
    Repo.insert!(
      struct(
        Session,
        Map.merge(
          %{
            id: random(),
            did: c.did,
            source_session_id: c.source,
            issuer: "https://pds.example.com",
            client_id: "https://client.example.com/metadata.json",
            scope: "atproto transition:generic",
            dpop_jkt: random(),
            refresh_digest: :crypto.strong_rand_bytes(32),
            expires_at: System.system_time(:second) + 3600
          },
          changes
        )
      )
    )
  end

  defp other_account(c) do
    did = "did:plc:foreignmanagement"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, pair} = Sessions.create_for_account(did, c.opts)
    {:ok, claims} = Tokens.verify(pair.access_jwt, :access, c.opts)
    %{c | did: did, source: claims["sid"]}
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
