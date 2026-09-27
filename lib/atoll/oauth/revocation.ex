defmodule Atoll.OAuth.Revocation do
  @moduledoc "Client-authenticated, DPoP-bound revocation of an entire OAuth grant."
  import Ecto.Query
  alias Atoll.Repo

  alias Atoll.OAuth.{
    AccessToken,
    ClientAssertions,
    ClientMetadata,
    PAR,
    Proofs,
    RefreshUse,
    Session
  }

  @fields ~w(client_id token token_type_hint client_assertion_type client_assertion)

  def revoke(params, headers, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    cond do
      Repo.in_transaction?() ->
        {:error, :oauth_revocation_inside_transaction}

      not valid_input?(params) ->
        {:error, :invalid_request}

      true ->
        with {:ok, proof} <-
               Proofs.verify(
                 headers,
                 "POST",
                 issuer <> "/oauth/revoke",
                 :authorization,
                 Keyword.take(opts, [:secret]) ++ [issuer: issuer]
               ),
             {:ok, binding} <- client(params, issuer, opts) do
          revoke_bound(params, issuer, proof.jkt, binding)
        end
    end
  rescue
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :oauth_revocation_store_unavailable}
  end

  defp valid_input?(params) when is_map(params) and map_size(params) in 2..5 do
    Enum.all?(params, fn {k, v} ->
      k in @fields and is_binary(v) and byte_size(v) in 1..8192 and String.valid?(v)
    end) and is_binary(params["token"]) and is_binary(params["client_id"]) and
      byte_size(params["client_id"]) <= 2048 and
      Enum.reduce(params, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end) <= 16_384
  end

  defp valid_input?(_), do: false

  defp client(params, issuer, opts) do
    if Map.has_key?(params, "client_assertion") or Map.has_key?(params, "client_assertion_type") do
      with {:ok, verified} <-
             ClientAssertions.authenticate(
               params["client_id"],
               params["client_assertion_type"],
               params["client_assertion"],
               issuer,
               opts
             ) do
        {:ok, Map.new(verified.binding, fn {key, value} -> {Atom.to_string(key), value} end)}
      end
    else
      with {:ok, %{"token_endpoint_auth_method" => "none"}} <-
             ClientMetadata.fetch(params["client_id"], opts),
           do: {:ok, nil},
           else: (_ -> {:error, :invalid_client})
    end
  end

  defp revoke_bound(params, issuer, jkt, binding) do
    digest = :crypto.hash(:sha256, params["token"])

    Repo.transaction(fn ->
      Atoll.Database.limits!(1_000, 5_000)
      # Serialize with refresh and exchange, including lookup of rotated tokens.
      PAR.lock!()
      session = find_session(digest)

      if session && session.issuer == issuer && session.client_id == params["client_id"] &&
           session.dpop_jkt == jkt && session.client_binding == binding do
        Repo.delete!(session, log: false)
      end

      # Unknown, foreign and previously revoked tokens have the same response.
      %{}
    end)
  end

  defp find_session(digest) do
    Repo.one(from(s in Session, where: s.refresh_digest == ^digest, lock: "FOR UPDATE"),
      log: false
    ) ||
      token_session(AccessToken, digest) || token_session(RefreshUse, digest)
  end

  defp token_session(schema, digest) do
    case Repo.get(schema, digest, log: false) do
      nil ->
        nil

      token ->
        Repo.one(from(s in Session, where: s.id == ^token.session_id, lock: "FOR UPDATE"),
          log: false
        )
    end
  end
end
