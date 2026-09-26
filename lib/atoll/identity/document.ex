defmodule Atoll.Identity.Document do
  @moduledoc """
  Extracts ATProto fields from an already-resolved DID document.

  This does not establish document authenticity or verify the claimed handle.
  The caller must obtain the document through the DID method's trusted resolver
  and verify the handle in both directions. Legacy key encodings are not supported.
  """
  alias Atoll.{Multikey, Syntax}

  def parse(%{"id" => did} = doc, expected_did) when did == expected_did do
    with true <- Syntax.did?(did),
         methods when is_list(methods) <- Map.get(doc, "verificationMethod", []),
         services when is_list(services) <- Map.get(doc, "service", []),
         aliases when is_list(aliases) <- Map.get(doc, "alsoKnownAs", []),
         key when not is_nil(key) <- Enum.find_value(methods, &signing_key(&1, did)),
         service when not is_nil(service) <- Enum.find(services, &pds_service?(&1, did)),
         {:ok, pds} <- endpoint(service["serviceEndpoint"]) do
      {:ok,
       %{
         did: did,
         signing_key: key,
         pds: pds,
         claimed_handle: Enum.find_value(aliases, &handle/1)
       }}
    else
      _ -> {:error, :invalid_did_document}
    end
  end

  def parse(_, _), do: {:error, :invalid_did_document}

  @doc "Extracts the uniquely identified account signing key from a resolved document."
  def account_key(%{"id" => did, "verificationMethod" => methods}, did) when is_list(methods) do
    matches =
      Enum.filter(methods, fn
        %{"id" => id} -> id in ["#atproto", did <> "#atproto"]
        _ -> false
      end)

    case matches do
      [method] ->
        case signing_key(method, did) do
          nil -> {:error, :invalid_did_document}
          key -> {:ok, key}
        end

      _ ->
        {:error, :invalid_did_document}
    end
  end

  def account_key(_, _), do: {:error, :invalid_did_document}

  defp signing_key(
         %{"id" => id, "controller" => did, "type" => "Multikey", "publicKeyMultibase" => value},
         did
       ) do
    if id in ["#atproto", did <> "#atproto"] do
      case Multikey.decode(value) do
        {:ok, key} -> key
        _ -> nil
      end
    end
  end

  defp signing_key(_, _), do: nil

  defp pds_service?(%{"id" => id, "type" => "AtprotoPersonalDataServer"}, did),
    do: id in ["#atproto_pds", did <> "#atproto_pds"]

  defp pds_service?(_, _), do: false

  defp endpoint(value) when is_binary(value) do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         userinfo: nil,
         path: path,
         query: nil,
         fragment: nil,
         port: port
       }}
      when is_binary(host) and host != "" and path in [nil, "", "/"] and port in 1..65535 ->
        {:ok, value}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_), do: {:error, :invalid_endpoint}

  defp handle("at://" <> name) do
    if Syntax.handle?(name), do: String.downcase(name)
  end

  defp handle(_), do: nil
end
