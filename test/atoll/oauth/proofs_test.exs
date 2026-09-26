defmodule Atoll.OAuth.ProofsTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{Nonce, Proofs, ProofUse}
  @url "https://pds.example.com/oauth/token"

  setup do
    now = now()
    opts = [secret: :crypto.strong_rand_bytes(32), issuer: "https://pds.example.com"]
    {:ok, nonce} = Nonce.issue(:authorization, Keyword.put(opts, :now, now))
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    %{opts: opts, nonce: nonce, key: key, now: now}
  end

  test "accepts once across calls and fresh nonces, without storing proof or token plaintext",
       c do
    proof = proof(c)
    assert {:ok, verified} = verify(c, proof)
    assert {:error, :dpop_replayed} = verify(c, proof)
    {:ok, fresh_nonce} = Nonce.issue(:authorization, c.opts)
    assert {:error, :dpop_replayed} = verify(c, proof(%{c | nonce: fresh_nonce}))
    stored = Repo.one!(ProofUse)
    assert byte_size(stored.digest) == 32
    assert stored.expires_at == c.now + 300
    refute stored.digest == :crypto.hash(:sha256, proof)
    assert verified.jti == "proof-id"
    assert {:ok, _} = verify(c, proof(c, %{"jti" => "another-proof"}))
    assert {:ok, _} = verify(c, proof(%{c | key: JOSE.JWK.generate_key({:ec, :secp256r1})}))
  end

  test "admission survives a later request rollback and rejects nested use", c do
    assert {:ok, _} = verify(c, proof(c))
    assert {:error, :request_failed} = Repo.transaction(fn -> Repo.rollback(:request_failed) end)
    assert {:error, :dpop_replayed} = verify(c, proof(c))

    assert {:ok, {:error, :oauth_proof_inside_transaction}} =
             Repo.transaction(fn -> verify(c, proof(c, %{"jti" => "new"})) end)

    assert Repo.aggregate(ProofUse, :count) == 1
  end

  test "independent database transactions admit a raced proof only once", c do
    token = proof(c)

    digest =
      :crypto.hash(
        :sha256,
        Atoll.CBOR.encode!([
          "atoll.oauth.dpop-use.v1",
          c.opts[:issuer],
          "authorization",
          JOSE.JWK.thumbprint(c.key),
          "proof-id"
        ])
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from u in ProofUse, where: u.digest == ^digest)
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        1..4,
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> verify(c, token) end)
        end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :dpop_replayed})) == 3
  end

  test "resource-server proof admission verifies nonce role and token binding", c do
    {:ok, nonce} = Nonce.issue(:resource, c.opts)
    access = "resource-access-token"
    url = "https://pds.example.com/xrpc/com.atproto.repo.getRecord"
    ath = :crypto.hash(:sha256, access) |> Base.url_encode64(padding: false)
    token = proof(%{c | nonce: nonce}, %{"htu" => url, "htm" => "GET", "ath" => ath})
    opts = c.opts ++ [access_token: access, jkt: JOSE.JWK.thumbprint(c.key)]

    assert {:error, :invalid_dpop_proof} =
             Proofs.verify([token], "GET", url, :resource, c.opts)

    assert {:ok, _} = Proofs.verify([token], "GET", url, :resource, opts)
    assert {:error, :dpop_replayed} = Proofs.verify([token], "GET", url, :resource, opts)
  end

  test "invalid signatures, nonces and token binding do not consume replay capacity", c do
    token = proof(c)

    assert {:error, :invalid_dpop_proof} =
             Proofs.verify([token], "GET", @url, :authorization, c.opts)

    assert {:error, :use_dpop_nonce} = Proofs.verify([token], "POST", @url, :resource, c.opts)

    assert {:error, :use_dpop_nonce} =
             verify(%{c | opts: Keyword.put(c.opts, :issuer, "https://other.example.com")}, token)

    assert {:error, :invalid_dpop_proof} =
             verify(
               %{c | opts: c.opts ++ [access_token: "token", jkt: JOSE.JWK.thumbprint(c.key)]},
               token
             )

    {:ok, expired} = Nonce.issue(:authorization, c.opts ++ [now: c.now - 301])
    assert {:error, :use_dpop_nonce} = verify(c, proof(%{c | nonce: expired}))
    assert Repo.aggregate(ProofUse, :count) == 0
    assert {:ok, _} = verify(c, token)
  end

  test "expiry reclamation is bounded and only removes expired markers", c do
    rows = for i <- 1..1005, do: %{digest: <<i::256>>, expires_at: c.now - 1}
    Repo.insert_all(ProofUse, rows)
    assert {:ok, _} = verify(c, proof(c))
    assert Repo.aggregate(ProofUse, :count) == 6
    assert {:error, :dpop_replayed} = verify(c, proof(c))
    assert Repo.aggregate(ProofUse, :count) == 6
  end

  test "full shared storage rejects new proofs and reclaims expired capacity", c do
    for chunk <- Enum.chunk_every(1..100_000, 10_000) do
      Repo.insert_all(ProofUse, Enum.map(chunk, &%{digest: <<&1::256>>, expires_at: c.now + 600}),
        log: false
      )
    end

    token = proof(c)
    assert {:error, :oauth_proof_store_full} = verify(c, token)
    assert Repo.aggregate(ProofUse, :count) == 100_000

    Repo.get!(ProofUse, <<1::256>>)
    |> Ecto.Changeset.change(expires_at: c.now - 1)
    |> Repo.update!()

    assert {:ok, _} = verify(c, token)
    assert Repo.aggregate(ProofUse, :count) == 100_000
    assert {:error, :dpop_replayed} = verify(c, token)
  end

  defp now do
    %{rows: [[value]]} =
      Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

    value
  end

  defp proof(c, changes \\ %{}) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    claims =
      Map.merge(
        %{
          "jti" => "proof-id",
          "htm" => "POST",
          "htu" => @url,
          "iat" => c.now,
          "nonce" => c.nonce
        },
        changes
      )

    JOSE.JWT.sign(c.key, %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => public}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp verify(c, token), do: Proofs.verify([token], "POST", @url, :authorization, c.opts)
end
