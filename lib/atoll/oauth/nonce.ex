defmodule Atoll.OAuth.Nonce do
  @moduledoc "Five-minute unpredictable DPoP nonces authenticated by issuer and server role. Options are trusted configuration."
  @ttl 300

  def secret_from_env!(nil), do: nil

  def secret_from_env!(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::256>> = secret} -> secret
      _ -> raise ArgumentError, "ATOLL_OAUTH_NONCE_SECRET must be a base64 32-byte key"
    end
  end

  def issue(role, opts \\ []) do
    with {:ok, secret, issuer} <- config(role, opts),
         now = Keyword.get(opts, :now, System.system_time(:second)),
         true <- is_integer(now) and now > 0 and now < 9_223_372_036_854_775_000 do
      payload = <<1, now::unsigned-big-64, :crypto.strong_rand_bytes(16)::binary>>
      {:ok, Base.url_encode64(payload <> mac(secret, issuer, role, payload), padding: false)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_nonce_configuration}
    end
  end

  def verify(value, role, opts \\ []) do
    with {:ok, secret, issuer} <- config(role, opts),
         true <- is_binary(value) and byte_size(value) == 76,
         {:ok,
          <<1, issued::unsigned-big-64, random::binary-size(16), tag::binary-size(32)>> = bytes} <-
           Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == value,
         true <-
           Plug.Crypto.secure_compare(
             tag,
             mac(secret, issuer, role, <<1, issued::unsigned-big-64, random::binary>>)
           ),
         now = Keyword.get(opts, :now, System.system_time(:second)),
         true <- is_integer(now) and issued <= now + 5 and now < issued + @ttl do
      {:ok, %{issuer: issuer, expires_at: issued + @ttl}}
    else
      {:error, :oauth_nonce_unconfigured} = error -> error
      _ -> {:error, :use_dpop_nonce}
    end
  end

  defp config(role, opts) when role in [:authorization, :resource] do
    secret = Keyword.get(opts, :secret, Application.get_env(:atoll, :oauth_nonce_secret))
    issuer = Keyword.get(opts, :issuer, AtollWeb.Endpoint.url())

    if match?(<<_::256>>, secret) and is_binary(issuer) and byte_size(issuer) in 1..2048,
      do: {:ok, secret, issuer},
      else: {:error, :oauth_nonce_unconfigured}
  end

  defp config(_, _), do: {:error, :invalid_nonce_configuration}

  defp mac(secret, issuer, role, payload),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        secret,
        Atoll.CBOR.encode!([
          "atoll.oauth.dpop-nonce.v1",
          issuer,
          Atom.to_string(role),
          %Atoll.CBOR.Bytes{data: payload}
        ])
      )
end
