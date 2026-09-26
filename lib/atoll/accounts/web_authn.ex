defmodule Atoll.Accounts.WebAuthn do
  @moduledoc """
  Bounded WebAuthn verification for user-verified ES256 discoverable credentials.

  This module does not authorize enrollment or issue sessions. A caller must
  persist unpredictable, expiring, one-use challenges bound to the browser and
  ceremony, authorize enrollment, enforce unique credential ownership, and lock
  credential state while checking and updating counters. Context and stored
  credential arguments are trusted server data, never client-supplied state.
  Requests must offer only ES256 (-7), require user verification and resident
  keys, and request `none` attestation. No authenticator provenance is asserted.
  """
  import Bitwise
  alias Atoll.Accounts.WebAuthn.CBOR
  alias Atoll.CBOR.Bytes

  @doc "Create a fresh challenge tied to an exact HTTPS origin (HTTP localhost for development)."
  def challenge(origin) when is_binary(origin) and byte_size(origin) <= 2048 do
    with {:ok, uri} <- URI.new(origin),
         true <- uri.scheme == "https" or (uri.scheme == "http" and uri.host == "localhost"),
         true <-
           is_binary(uri.host) and (uri.host == "localhost" or Atoll.Syntax.handle?(uri.host)),
         true <- uri.host == String.downcase(uri.host),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, ""],
         true <- is_integer(uri.port) and uri.port in 1..65535,
         true <- URI.to_string(uri) == origin do
      {:ok, %{challenge: :crypto.strong_rand_bytes(32), origin: origin, rp_id: uri.host}}
    else
      _ -> {:error, :invalid_webauthn_origin}
    end
  end

  def challenge(_), do: {:error, :invalid_webauthn_origin}

  @doc "Verify an unattested registration; returned public credential data still needs authorized persistence."
  def register(response, %{challenge: <<_::256>>, origin: origin, rp_id: rp_id} = context)
      when is_binary(origin) and is_binary(rp_id) do
    with {:ok, id, payload} <- envelope(response),
         {:ok, _client} <- client_data(payload["clientDataJSON"], context, "webauthn.create"),
         {:ok, object} <- unbase(payload["attestationObject"], 16_384),
         {:ok, %{"fmt" => "none", "attStmt" => statement, "authData" => %Bytes{data: data}}}
         when is_map(statement) and map_size(statement) == 0 <- CBOR.decode(object),
         {:ok, flags, count, rest} <- authenticator(data, rp_id),
         true <- (flags &&& 64) != 0,
         <<aaguid::binary-size(16), size::16, rest::binary>> <- rest,
         true <- size in 1..1023,
         <<credential_id::binary-size(size), rest::binary>> <- rest,
         true <- credential_id == id,
         {:ok, cose, rest} <- CBOR.prefix(rest),
         {:ok, point} <- public_key(cose),
         :ok <- extensions(flags, rest) do
      {:ok,
       %{
         credential_id: id,
         public_key: point,
         sign_count: count,
         backup_eligible: (flags &&& 8) != 0,
         backup_state: (flags &&& 16) != 0,
         aaguid: aaguid
       }}
    else
      _ -> invalid()
    end
  end

  def register(_, _), do: invalid()

  @doc "Verify an assertion against a locked stored credential; persist the returned counter and backup state."
  def authenticate(response, %{challenge: <<_::256>>, origin: origin, rp_id: rp_id} = context, %{
        credential_id: id,
        public_key: <<4, _::binary-size(64)>> = key,
        user_handle: <<_::256>> = user,
        sign_count: previous,
        backup_eligible: eligible
      })
      when is_binary(origin) and is_binary(rp_id) and is_boolean(eligible) and
             is_integer(previous) and previous in 0..4_294_967_295 do
    with {:ok, ^id, payload} <- envelope(response),
         {:ok, client} <- client_data(payload["clientDataJSON"], context, "webauthn.get"),
         {:ok, ^user} <- unbase(payload["userHandle"], 32),
         {:ok, data} <- unbase(payload["authenticatorData"], 4096),
         {:ok, flags, count, rest} <- authenticator(data, rp_id),
         true <- (flags &&& 64) == 0,
         true <- (flags &&& 8) != 0 == eligible,
         :ok <- extensions(flags, rest),
         {:ok, signature} <- unbase(payload["signature"], 72),
         true <- verify(key, data <> :crypto.hash(:sha256, client), signature),
         true <- (count == 0 and previous == 0) or count > previous do
      {:ok, %{sign_count: count, backup_state: (flags &&& 16) != 0}}
    else
      _ -> invalid()
    end
  end

  def authenticate(_, _, _), do: invalid()

  defp envelope(%{
         "type" => "public-key",
         "id" => encoded,
         "rawId" => encoded,
         "response" => payload
       })
       when is_map(payload) do
    with {:ok, id} when byte_size(id) in 1..1023 <- unbase(encoded, 1023),
         do: {:ok, id, payload},
         else: (_ -> invalid())
  end

  defp envelope(_), do: invalid()

  defp client_data(encoded, context, type) do
    with {:ok, raw} <- unbase(encoded, 4096),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(raw, objects: :ordered_objects),
         true <- length(pairs) == map_size(Map.new(pairs)),
         data = Map.new(pairs),
         ^type <- data["type"],
         true <- data["challenge"] == Base.url_encode64(context.challenge, padding: false),
         true <- data["origin"] == context.origin,
         false <- Map.get(data, "crossOrigin", false),
         false <- Map.has_key?(data, "topOrigin") do
      {:ok, raw}
    else
      _ -> invalid()
    end
  end

  defp authenticator(<<hash::binary-size(32), flags, count::32, rest::binary>>, rp_id) do
    if Plug.Crypto.secure_compare(hash, :crypto.hash(:sha256, rp_id)) and
         (flags &&& 5) == 5 and ((flags &&& 16) == 0 or (flags &&& 8) != 0),
       do: {:ok, flags, count, rest},
       else: invalid()
  end

  defp authenticator(_, _), do: invalid()

  defp extensions(flags, <<>>) when (flags &&& 128) == 0, do: :ok

  defp extensions(flags, bytes) when (flags &&& 128) != 0 do
    case CBOR.decode(bytes) do
      {:ok, value} when is_map(value) ->
        if Enum.all?(Map.keys(value), &is_binary/1), do: :ok, else: invalid()

      _ ->
        invalid()
    end
  end

  defp extensions(_, _), do: invalid()

  defp public_key(
         %{
           1 => 2,
           3 => -7,
           -1 => 1,
           -2 => %Bytes{data: <<_::256>> = x},
           -3 => %Bytes{data: <<_::256>> = y}
         } = cose
       )
       when map_size(cose) == 5 do
    point = <<4, x::binary, y::binary>>
    # Ask OTP/OpenSSL to validate the point on P-256, including non-infinity.
    case :crypto.compute_key(:ecdh, point, <<1::256>>, :secp256r1) do
      <<_::256>> -> {:ok, point}
      _ -> invalid()
    end
  catch
    :error, _ -> invalid()
  end

  defp public_key(_), do: invalid()

  defp verify(key, message, signature) do
    :crypto.verify(:ecdsa, :sha256, message, signature, [key, :secp256r1])
  catch
    :error, _ -> false
  end

  defp unbase(value, max) when is_binary(value) and byte_size(value) <= div(max * 4 + 2, 3) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- byte_size(decoded) <= max and Base.url_encode64(decoded, padding: false) == value,
         do: {:ok, decoded},
         else: (_ -> invalid())
  end

  defp unbase(_, _), do: invalid()
  defp invalid, do: {:error, :invalid_webauthn}
end
