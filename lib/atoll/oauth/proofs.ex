defmodule Atoll.OAuth.Proofs do
  @moduledoc """
  Internal nonce/proof verification with PostgreSQL-shared replay admission.
  Must run before the request's mutation transaction, so a later rollback cannot
  make a used proof reusable. This does not authorize accounts, clients or scopes.
  """
  alias Atoll.Repo
  alias Atoll.OAuth.{Admission, DPoP, Nonce, ProofUse}
  @lock 4_182_026_050
  @capacity 100_000

  def verify(headers, method, url, role, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :oauth_proof_inside_transaction}
    else
      Repo.transaction(fn ->
        now = Admission.start!()
        nonce = unwrap!(DPoP.peek_nonce(headers))
        nonce_opts = Keyword.take(opts, [:secret, :issuer]) |> Keyword.put(:now, now)
        verified_nonce = unwrap!(Nonce.verify(nonce, role, nonce_opts))

        if role == :resource and
             (not is_binary(opts[:access_token]) or not is_binary(opts[:jkt])),
           do: Repo.rollback(:invalid_dpop_proof)

        proof_opts = Keyword.take(opts, [:access_token, :jkt]) ++ [now: now, nonce: nonce]
        proof = unwrap!(DPoP.verify(headers, method, url, proof_opts))

        # Separate from repository locks; shared by proof admission and pruning.
        now = Admission.lock_now!(@lock)

        if now >= verified_nonce.expires_at or now > proof.issued_at + 300,
          do: Repo.rollback(:use_dpop_nonce)

        Admission.prune!(ProofUse, now)

        digest =
          :crypto.hash(
            :sha256,
            Atoll.CBOR.encode!([
              "atoll.oauth.dpop-use.v1",
              verified_nonce.issuer,
              Atom.to_string(role),
              proof.jkt,
              proof.jti
            ])
          )

        if Repo.get(ProofUse, digest, log: false), do: Repo.rollback(:dpop_replayed)

        if Repo.aggregate(ProofUse, :count) >= @capacity,
          do: Repo.rollback(:oauth_proof_store_full)

        Repo.insert!(%ProofUse{digest: digest, expires_at: verified_nonce.expires_at}, log: false)
        proof
      end)
    end
  rescue
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_proof_store_unavailable}
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
