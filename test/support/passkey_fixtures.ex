defmodule Atoll.PasskeyFixtures do
  @moduledoc false
  alias Atoll.CBOR.Bytes

  def new(options) do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)

    %{
      context: context(options),
      private: private,
      stored: %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: public,
        user_handle: unbase(options.user.id),
        sign_count: 0,
        backup_eligible: false
      }
    }
  end

  def context(options),
    do: %{
      challenge: unbase(options.challenge),
      origin: AtollWeb.Endpoint.url(),
      rp_id: options[:rpId] || options.rp.id
    }

  def registration(c, opts \\ []) do
    <<4, x::binary-size(32), y::binary-size(32)>> = c.stored.public_key

    cose =
      Keyword.get(
        opts,
        :cose,
        <<0xA5, 1, 2, 3, 0x26, 0x20, 1, 0x21, 0x58, 32, x::binary, 0x22, 0x58, 32, y::binary>>
      )

    id = Keyword.get(opts, :credential_id, c.stored.credential_id)

    data =
      auth_data(c, Keyword.put_new(opts, :flags, 69)) <>
        <<0::128, byte_size(id)::16, id::binary, cose::binary>> <> Keyword.get(opts, :tail, "")

    object =
      Atoll.CBOR.encode!(%{
        "fmt" => Keyword.get(opts, :fmt, "none"),
        "attStmt" => Keyword.get(opts, :statement, %{}),
        "authData" => %Bytes{data: data}
      })

    envelope(c, %{
      "attestationObject" => base(object),
      "clientDataJSON" =>
        base(client(c.context, "webauthn.create", Keyword.get(opts, :client, %{})))
    })
  end

  def assertion(c, opts \\ []) do
    data = auth_data(c, Keyword.put_new(opts, :count, 1)) <> Keyword.get(opts, :tail, "")
    raw = client(c.context, "webauthn.get", Keyword.get(opts, :client, %{}))

    signature =
      :crypto.sign(:ecdsa, :sha256, data <> :crypto.hash(:sha256, raw), [c.private, :secp256r1])

    envelope(c, %{
      "authenticatorData" => base(data),
      "signature" => base(signature),
      "clientDataJSON" => base(raw),
      "userHandle" => base(c.stored.user_handle)
    })
  end

  defp auth_data(c, opts),
    do:
      :crypto.hash(:sha256, Keyword.get(opts, :rp_id, c.context.rp_id)) <>
        <<Keyword.get(opts, :flags, 5), Keyword.get(opts, :count, 0)::32>>

  defp client(ctx, type, extra),
    do:
      Map.merge(
        %{type: type, challenge: base(ctx.challenge), origin: ctx.origin, crossOrigin: false},
        extra
      )
      |> Jason.encode!()

  defp envelope(c, payload),
    do: %{
      "id" => base(c.stored.credential_id),
      "rawId" => base(c.stored.credential_id),
      "type" => "public-key",
      "response" => payload
    }

  defp base(bytes), do: Base.url_encode64(bytes, padding: false)
  defp unbase(bytes), do: Base.url_decode64!(bytes, padding: false)
end
