defmodule Atoll.Accounts.ServiceAuth do
  @moduledoc "Short-lived service JWT issuance using an active account's repository signing key."
  alias Atoll.{KeyVault, Repo, SigningKey, Syntax}
  alias Atoll.Accounts.Sessions

  # Account-management methods must be called directly, not delegated via service JWTs.
  @protected ~w(
    com.atproto.admin.sendEmail
    com.atproto.identity.requestPlcOperationSignature
    com.atproto.identity.signPlcOperation
    com.atproto.identity.updateHandle
    com.atproto.server.activateAccount
    com.atproto.server.confirmEmail
    com.atproto.server.createAppPassword
    com.atproto.server.deactivateAccount
    com.atproto.server.getAccountInviteCodes
    com.atproto.server.getSession
    com.atproto.server.listAppPasswords
    com.atproto.server.requestAccountDelete
    com.atproto.server.requestEmailConfirmation
    com.atproto.server.requestEmailUpdate
    com.atproto.server.revokeAppPassword
    com.atproto.server.updateEmail
  ) |> Enum.map(&String.downcase/1)

  def issue(token, params) when is_map(params), do: issue(token, params, :delegation)

  @doc "Admit a proxy caller, prepare outside locks, and recheck the active session before signing."
  def with_proxy(token, audience, nsid, prepare) when is_function(prepare, 0) do
    params = %{"aud" => audience, "lxm" => nsid, "token_aud" => bare_audience(audience)}

    cond do
      Repo.in_transaction?() ->
        {:error, :proxy_inside_transaction}

      not (audience?(audience) and String.contains?(audience, "#") and Syntax.nsid?(nsid)) ->
        {:error, :invalid_request}

      true ->
        with :ok <- method(nsid),
             {:ok, _} <- authorize_session(token, params, :proxy),
             {:ok, prepared, overrides} <- prepared(prepare.()),
             {:ok, %{token: jwt}} <- issue(token, Map.merge(params, overrides), :proxy) do
          {:ok, {prepared, jwt}}
        end
    end
  end

  defp prepared({:ok, prepared}), do: {:ok, prepared, %{}}
  defp prepared({:ok, prepared, %{} = overrides}), do: {:ok, prepared, overrides}
  defp prepared(error), do: error

  # Phase 1 of upstream service-auth: proxied grants check the did#service form
  # while their outbound JWTs carry a bare DID audience. Delegated tokens keep
  # the audience the caller requested.
  @doc false
  def token_claims(params),
    do: {params["token_aud"] || params["aud"], Map.get(params, "token_lxm", params["lxm"])}

  @doc false
  def bare_audience(audience), do: audience |> String.split("#") |> hd()

  defp issue(token, params, policy) do
    with true <- audience?(params["aud"]),
         :ok <- method(params["lxm"]),
         {:ok, expiry} <- expiration(params["exp"]) do
      Repo.transaction(fn ->
        {aud, lxm} = token_claims(params)

        with {:ok, %{did: did}} <- authorize_session(token, params, policy),
             now = System.system_time(:second),
             {:ok, exp} <- bounded_expiry(expiry, params["lxm"], now),
             {:ok, key} <- KeyVault.fetch(did),
             {:ok, jwt} <- sign(key, did, aud, lxm, now, exp) do
          %{token: jwt}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc """
  Internal signing callback for OAuth.Resource.read; the caller must hold its
  authorization locks. This function is not an authentication boundary.
  """
  def issue_oauth(%{did: did, status: :active} = principal, params) when is_map(params) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "OAuth service signing requires an authorized transaction")

    {aud, lxm} = token_claims(params)

    with :ok <- authorize_oauth(principal, params),
         {:ok, expiry} <- expiration(params["exp"]),
         now = System.system_time(:second),
         {:ok, exp} <- bounded_expiry(expiry, params["lxm"], now),
         {:ok, key} <- KeyVault.fetch(did),
         {:ok, jwt} <- sign(key, did, aud, lxm, now, exp) do
      {:ok, %{token: jwt}}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @doc "Pure permission check for an already authenticated OAuth principal; not an authentication boundary."
  def authorize_oauth(%{status: :active, scope: scope}, params) when is_map(params) do
    with true <- audience?(params["aud"]),
         :ok <- method(params["lxm"]),
         do: oauth_scope(scope, params["aud"], params["lxm"]),
         else: (
           false -> {:error, :invalid_request}
           error -> error
         )
  end

  def authorize_oauth(_, _), do: {:error, :invalid_token}

  defp authorize_session(token, params, policy) do
    with {:ok, head} <- Sessions.authenticate_session(token),
         :ok <- account_scope(head, params["lxm"]),
         true <- policy != :proxy or head.status == :active,
         :ok <- app_scope(head.scope, params["lxm"]) do
      {:ok, head}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp oauth_scope(scope, audience, method) do
    scopes = String.split(scope, " ")
    normalized = if method, do: String.downcase(method)

    transitional =
      "transition:generic" in scopes and
        normalized != "com.atproto.server.createaccount" and
        (is_nil(normalized) or not String.starts_with?(normalized, "chat.bsky.") or
           "transition:chat.bsky" in scopes)

    if transitional or Atoll.OAuth.Permissions.allows_rpc?(scope, audience, method || "*"),
      do: :ok,
      else: {:error, :insufficient_scope}
  end

  defp app_scope("com.atproto.access", _), do: :ok
  defp app_scope(_, nil), do: {:error, :forbidden}

  defp app_scope(scope, method) do
    method = String.downcase(method)

    if method == "com.atproto.server.createaccount" or
         (scope == "com.atproto.appPass" and String.starts_with?(method, "chat.bsky.")),
       do: {:error, :forbidden},
       else: :ok
  end

  defp account_scope(%{status: :active}, _method), do: :ok
  defp account_scope(%{status: :deactivated}, "com.atproto.server.createAccount"), do: :ok
  defp account_scope(_, _), do: {:error, {:repo_inactive, :deactivated}}

  defp audience?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case String.split(value, "#") do
      [did] ->
        Syntax.did?(did)

      [did, fragment] ->
        Syntax.did?(did) and
          Regex.match?(~r/\A(?:[A-Za-z0-9._~!$&'()*+,;=:@\/?-]|%[0-9a-fA-F]{2})+\z/, fragment)

      _ ->
        false
    end
  end

  defp audience?(_), do: false
  defp method(nil), do: :ok

  defp method(value) do
    if Syntax.nsid?(value) and String.downcase(value) not in @protected,
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp expiration(nil), do: {:ok, nil}

  defp expiration(value) when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(value) do
      {exp, ""} -> {:ok, exp}
      _ -> {:error, :bad_expiration}
    end
  end

  defp expiration(_), do: {:error, :bad_expiration}

  defp bounded_expiry(nil, _method, now), do: {:ok, now + 60}

  defp bounded_expiry(exp, method, now) do
    max_age = if method, do: 3600, else: 60
    if exp > now and exp <= now + max_age, do: {:ok, exp}, else: {:error, :bad_expiration}
  end

  defp sign(key, did, audience, method, now, exp) do
    header = %{typ: "JWT", alg: if(key.curve == :k256, do: "ES256K", else: "ES256")}

    claims = %{
      iss: did,
      aud: audience,
      iat: now,
      exp: exp,
      jti: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }

    claims = if method, do: Map.put(claims, :lxm, method), else: claims
    input = encode(header) <> "." <> encode(claims)

    with {:ok, signature} <- SigningKey.sign(key, input),
         do: {:ok, input <> "." <> Base.url_encode64(signature, padding: false)}
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)
end
