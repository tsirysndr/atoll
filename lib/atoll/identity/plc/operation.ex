defmodule Atoll.Identity.PLC.Operation do
  @moduledoc """
  PLC operation signing and cryptographic verification. No network or persistence.
  Update verification requires an already-trusted predecessor. This module does
  not establish audit-log ordering, nullification, or recovery-window validity.
  """
  alias Atoll.{CBOR, CID, Multikey, SigningKey, Syntax}
  @regular ~w(type rotationKeys verificationMethods alsoKnownAs services prev)
  @legacy ~w(type signingKey recoveryKey handle service prev)
  @max_bytes 7500

  def create_atproto(signing_key, handle, endpoint, rotation_keys, signer)
      when is_binary(handle) do
    unsigned = %{
      "type" => "plc_operation",
      "rotationKeys" => rotation_keys,
      "verificationMethods" => %{"atproto" => signing_key},
      "alsoKnownAs" => ["at://" <> handle],
      "services" => %{
        "atproto_pds" => %{"type" => "AtprotoPersonalDataServer", "endpoint" => endpoint}
      },
      "prev" => nil
    }

    with true <-
           Syntax.handle?(handle) and handle == String.downcase(handle) and endpoint?(endpoint),
         {:ok, _} <- Multikey.from_did_key(signing_key),
         {:ok, operation} <- sign(unsigned, signer),
         {:ok, did} <- genesis_did(operation),
         {:ok, cid} <- cid(operation) do
      {:ok, %{did: did, operation: operation, cid: cid}}
    else
      _ -> {:error, :invalid_plc_operation}
    end
  end

  def create_atproto(_, _, _, _, _), do: {:error, :invalid_plc_operation}

  @doc "Signs a modern unsigned operation. The caller must authorize update/tombstone signing."
  def sign(unsigned, key) when is_map(unsigned) do
    with true <- unsigned["type"] in ["plc_operation", "plc_tombstone"],
         true <- shape?(unsigned),
         true <-
           byte_size(CBOR.encode!(Map.put(unsigned, "sig", String.duplicate("A", 86)))) <=
             @max_bytes,
         {:ok, signature} <- SigningKey.sign(key, CBOR.encode!(unsigned)) do
      {:ok, Map.put(unsigned, "sig", Base.url_encode64(signature, padding: false))}
    else
      _ -> {:error, :invalid_plc_operation}
    end
  rescue
    ArgumentError -> {:error, :invalid_plc_operation}
  end

  def sign(_, _), do: {:error, :invalid_plc_operation}

  @doc "Verifies a signed operation against the supplied authorized rotation keys; returns the signer."
  def verify(operation, keys) do
    with {:ok, unsigned, signature, _bytes} <- decode(operation),
         true <- keys?(keys),
         input = CBOR.encode!(unsigned),
         signer when is_binary(signer) <-
           Enum.find(keys, fn key ->
             {:ok, decoded} = Multikey.from_did_key(key)
             SigningKey.verify(decoded.curve, decoded.public, input, signature)
           end) do
      {:ok, signer}
    else
      _ -> {:error, :invalid_plc_operation}
    end
  end

  @doc "Derives a self-authenticating DID after verifying a modern or legacy genesis operation."
  def genesis_did(operation) when is_map(operation) do
    with true <- operation["prev"] == nil and operation["type"] in ["plc_operation", "create"],
         {:ok, _} <- verify(operation, rotation_keys(operation)),
         {:ok, _, _, bytes} <- decode(operation) do
      suffix =
        :crypto.hash(:sha256, bytes)
        |> Base.encode32(case: :lower, padding: false)
        |> binary_part(0, 24)

      {:ok, "did:plc:" <> suffix}
    else
      _ -> {:error, :invalid_plc_operation}
    end
  end

  def genesis_did(_), do: {:error, :invalid_plc_operation}

  def verify_genesis(did, operation) do
    case genesis_did(operation) do
      {:ok, ^did} -> :ok
      _ -> {:error, :invalid_plc_operation}
    end
  end

  @doc "Checks predecessor CID and signature; predecessor must already be trusted. Recovery rules are separate."
  def verify_update(previous, operation) when is_map(previous) and is_map(operation) do
    with true <- previous["type"] in ["plc_operation", "create"],
         true <- operation["type"] in ["plc_operation", "plc_tombstone"],
         {:ok, prev} <- cid(previous),
         true <- operation["prev"] == prev do
      verify(operation, rotation_keys(previous))
    else
      _ -> {:error, :invalid_plc_operation}
    end
  end

  def verify_update(_, _), do: {:error, :invalid_plc_operation}

  @doc "Hashes canonical signed bytes. Structural validation alone does not authenticate the operation."
  def cid(operation) do
    with {:ok, _, _, bytes} <- decode(operation),
         do: {:ok, bytes |> CID.create(:dag_cbor) |> CID.to_base32()}
  end

  defp decode(%{"sig" => encoded} = operation)
       when is_binary(encoded) and byte_size(encoded) == 86 do
    unsigned = Map.delete(operation, "sig")

    with true <- shape?(unsigned),
         {:ok, <<_::binary-size(64)>> = signature} <- Base.url_decode64(encoded, padding: false),
         true <- Base.url_encode64(signature, padding: false) == encoded,
         bytes = CBOR.encode!(operation),
         true <- byte_size(bytes) <= @max_bytes do
      {:ok, unsigned, signature, bytes}
    else
      _ -> {:error, :invalid_plc_operation}
    end
  rescue
    ArgumentError -> {:error, :invalid_plc_operation}
  end

  defp decode(_), do: {:error, :invalid_plc_operation}

  defp shape?(
         %{
           "type" => "plc_operation",
           "prev" => prev,
           "rotationKeys" => keys,
           "verificationMethods" => methods,
           "alsoKnownAs" => aliases,
           "services" => services
         } = op
       ) do
    exact?(op, @regular) and (is_nil(prev) or cid?(prev)) and keys?(keys) and
      is_map(methods) and not is_struct(methods) and
      Enum.all?(methods, fn {id, key} -> text?(id) and did_key?(key) end) and
      is_list(aliases) and Enum.all?(aliases, &text?/1) and
      is_map(services) and not is_struct(services) and
      Enum.all?(services, fn {id, service} -> text?(id) and service?(service) end)
  end

  defp shape?(%{"type" => "plc_tombstone", "prev" => prev} = op),
    do: exact?(op, ~w(type prev)) and cid?(prev)

  defp shape?(
         %{
           "type" => "create",
           "prev" => nil,
           "signingKey" => signing,
           "recoveryKey" => recovery,
           "handle" => handle,
           "service" => service
         } = op
       ) do
    exact?(op, @legacy) and keys?(Enum.uniq([recovery, signing])) and text?(handle) and
      text?(service)
  end

  defp shape?(_), do: false
  defp exact?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp service?(%{"type" => type, "endpoint" => endpoint} = service),
    do: map_size(service) == 2 and text?(type) and text?(endpoint)

  defp service?(_), do: false
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp did_key?("did:key:z" <> value), do: Regex.match?(~r/\A[1-9A-HJ-NP-Za-km-z]+\z/, value)
  defp did_key?(_), do: false

  defp keys?(keys) when is_list(keys) and length(keys) in 1..5,
    do: Enum.uniq(keys) == keys and Enum.all?(keys, &match?({:ok, _}, Multikey.from_did_key(&1)))

  defp keys?(_), do: false

  defp rotation_keys(%{"type" => "create"} = op),
    do: Enum.uniq([op["recoveryKey"], op["signingKey"]])

  defp rotation_keys(op), do: op["rotationKeys"]

  defp cid?(value) do
    with {:ok, bytes} <- CID.from_base32(value),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(bytes),
         do: true,
         else: (_ -> false)
  end

  defp endpoint?(value) when is_binary(value) and byte_size(value) <= 2048 do
    uri = URI.parse(value)

    uri.scheme == "https" and uri.port in 1..65_535 and is_binary(uri.host) and
      Syntax.handle?(uri.host) and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
      uri.path in [nil, "", "/"]
  rescue
    ArgumentError -> false
  end

  defp endpoint?(_), do: false
end
