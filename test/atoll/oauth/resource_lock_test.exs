defmodule Atoll.OAuth.ResourceLockTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{Resource, Nonce, Session, AccessToken, ProofUse}
  alias Atoll.Repositories.Head
  alias Atoll.Accounts.Session, as: AccountSession

  test "authorization rows remain locked through a read and deletion prevents later reads" do
    did = "did:plc:resourcelock#{System.unique_integer([:positive])}"
    key = Atoll.SigningKey.generate()
    {:ok, tree} = Atoll.MST.new()
    {:ok, rev} = Atoll.TID.next()
    {:ok, commit} = Atoll.Commit.create(did, tree.root, rev, key)
    token = "atoll_access_" <> random()
    digest = :crypto.hash(:sha256, token)
    source_id = random()
    session_id = random()
    dpop = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(dpop)
    jkt = JOSE.JWK.thumbprint(dpop)
    issuer = "https://pds.example.com"
    url = issuer <> "/xrpc/com.atproto.server.getSession"
    opts = [issuer: issuer, secret: :crypto.strong_rand_bytes(32)]
    {:ok, nonce} = Nonce.issue(:resource, opts)
    jti = random()

    proof_digest =
      :crypto.hash(
        :sha256,
        Atoll.CBOR.encode!(["atoll.oauth.dpop-use.v1", issuer, "resource", jkt, jti])
      )

    signed =
      JOSE.JWT.sign(dpop, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
        "jti" => jti,
        "iat" => System.system_time(:second),
        "nonce" => nonce,
        "htm" => "GET",
        "htu" => url,
        "ath" => Base.url_encode64(digest, padding: false)
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from h in Head, where: h.did == ^did)
        Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid == ^commit.cid)
        Repo.delete_all(from p in ProofUse, where: p.digest == ^proof_digest)
      end)
    end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      :ok = Atoll.Storage.put_block(commit.cid, commit.bytes)

      Repo.insert!(%Head{
        did: did,
        head: commit.cid,
        rev: rev,
        curve: key.curve,
        public_key: key.public
      })

      expires = System.system_time(:second) + 300

      Repo.insert!(%AccountSession{
        id: source_id,
        did: did,
        refresh_hash: :crypto.strong_rand_bytes(32),
        expires_at: expires
      })

      Repo.insert!(%Session{
        id: session_id,
        did: did,
        source_session_id: source_id,
        issuer: issuer,
        client_id: "https://app.example.com/metadata.json",
        scope: "atproto",
        dpop_jkt: jkt,
        expires_at: expires
      })

      Repo.insert!(%AccessToken{
        digest: digest,
        session_id: session_id,
        scope: "atproto",
        expires_at: expires
      })
    end)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Resource.read(
            token,
            [signed],
            url,
            fn principal ->
              send(parent, {:reading, self()})

              receive do
                :finish_read -> principal.did
              after
                5000 -> flunk("read was not released")
              end
            end,
            opts
          )
        end)
      end)

    assert_receive {:reading, reader}, 5000

    try do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        for {sql, value} <- [
              {"SELECT did FROM repositories WHERE did = $1 FOR UPDATE NOWAIT", did},
              {"SELECT id FROM account_sessions WHERE id = $1 FOR UPDATE NOWAIT", source_id},
              {"SELECT id FROM oauth_sessions WHERE id = $1 FOR UPDATE NOWAIT", session_id},
              {"SELECT digest FROM oauth_access_tokens WHERE digest = $1 FOR UPDATE NOWAIT",
               digest}
            ] do
          error =
            assert_raise Postgrex.Error, fn ->
              Repo.transaction(fn -> Repo.query!(sql, [value], log: false) end)
            end

          assert error.postgres.code == :lock_not_available
        end
      end)
    after
      send(reader, :finish_read)
    end

    assert Task.await(task) == {:ok, did}

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from s in Session, where: s.id == ^session_id)

      assert {:error, :invalid_token} =
               Resource.read(token, [signed], url, fn _ -> flunk("revoked read") end, opts)
    end)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
