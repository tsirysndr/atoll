defmodule Atoll.Accounts.Tokens do
  @moduledoc """
  Locally signed HS256 session JWTs. Options are for trusted internal callers only.
  Access tokens live for two hours; refresh tokens live for ninety days.
  Cryptographic verification alone does not establish that a session is still live.
  """
  alias Atoll.Syntax
  @access_ttl 7_200
  @refresh_ttl 90 * 86_400

  def random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  def digest(value), do: :crypto.hash(:sha256, value)

  def pair(did, session_id, opts \\ []) do
    with {:ok, key, audience} <- configuration(opts),
         true <- Syntax.did?(did) and valid_id?(session_id),
         scope = Keyword.get(opts, :access_scope, "com.atproto.access"),
         true <-
           scope in [
             "com.atproto.access",
             "com.atproto.appPass",
             "com.atproto.appPassPrivileged",
             "com.atproto.takendown"
           ] do
      now = Keyword.get(opts, :now, System.system_time(:second))
      jti = random_id()
      claims = %{"sub" => did, "aud" => audience, "iat" => now, "sid" => session_id}

      {:ok,
       %{
         access_jwt: sign(key, Map.put(claims, "scope", scope), :access, now),
         refresh_jwt: sign(key, Map.put(claims, "jti", jti), :refresh, now),
         refresh_hash: digest(jti),
         expires_at: now + @refresh_ttl
       }}
    else
      false -> {:error, :invalid_token}
      error -> error
    end
  end

  def verify(token, kind, opts \\ [])

  def verify(token, kind, opts)
      when is_binary(token) and byte_size(token) <= 8192 and kind in [:access, :refresh] do
    with {:ok, key, audience} <- configuration(opts) do
      verify_signed(
        token,
        kind,
        key,
        audience,
        Keyword.get(opts, :now, System.system_time(:second))
      )
    end
  end

  def verify(_, _, _), do: {:error, :invalid_token}

  defp verify_signed(token, kind, key, audience, now) do
    {typ, _scope, ttl} = profile(kind)

    with {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: header, b64: :undefined}} <-
           JOSE.JWT.verify_strict(key, ["HS256"], token),
         true <- header == %{"typ" => typ},
         %{
           "sub" => did,
           "aud" => ^audience,
           "scope" => scope,
           "sid" => sid,
           "iat" => issued,
           "exp" => expires
         } <- claims,
         true <- valid_scope?(kind, scope),
         true <- Syntax.did?(did) and valid_id?(sid),
         true <- kind == :access or valid_id?(claims["jti"]),
         true <-
           is_integer(issued) and is_integer(expires) and issued >= 0 and
             issued <= now and expires - issued == ttl do
      if expires > now, do: {:ok, claims}, else: {:error, :expired_token}
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  catch
    _, _ -> {:error, :invalid_token}
  end

  defp sign(key, claims, kind, now) do
    {typ, scope, ttl} = profile(kind)

    key
    |> JOSE.JWT.sign(
      %{"alg" => "HS256", "typ" => typ},
      Map.merge(claims, %{"scope" => Map.get(claims, "scope", scope), "exp" => now + ttl})
    )
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp configuration(opts) do
    secret = Keyword.get(opts, :secret, Application.get_env(:atoll, :session_signing_key))
    audience = Keyword.get(opts, :audience, Application.get_env(:atoll, :pds, [])[:did])

    if is_binary(secret) and byte_size(secret) == 32 and Syntax.did?(audience),
      do: {:ok, JOSE.JWK.from_oct(secret), audience},
      else: {:error, :session_configuration_missing}
  end

  defp valid_scope?(:access, scope),
    do:
      scope in [
        "com.atproto.access",
        "com.atproto.appPass",
        "com.atproto.appPassPrivileged",
        "com.atproto.takendown"
      ]

  defp valid_scope?(:refresh, scope), do: scope == "com.atproto.refresh"

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, id)
  defp valid_id?(_), do: false
  defp profile(:access), do: {"at+jwt", "com.atproto.access", @access_ttl}
  defp profile(:refresh), do: {"refresh+jwt", "com.atproto.refresh", @refresh_ttl}
end
