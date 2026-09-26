defmodule Atoll.Identity.PLC.AuditLog do
  @moduledoc "Independent bounded verification of supplied PLC audit history, including recovery nullifications."
  alias Atoll.Identity.PLC.Operation
  @window_us 72 * 60 * 60 * 1_000_000

  def verify(did, entries) when is_list(entries) and length(entries) in 1..1000 do
    [first | remaining] = Enum.map(entries, &entry!(&1, did))
    :ok = Operation.verify_genesis(did, first.operation)

    initial = %{
      chain: [first],
      seen: MapSet.new([first.cid]),
      nullified: MapSet.new(),
      latest: first.time
    }

    state = Enum.reduce(remaining, initial, &advance!/2)

    for entry <- [first | remaining] do
      unless entry.nullified == MapSet.member?(state.nullified, entry.cid), do: throw(:invalid)
    end

    [head | _] = state.chain

    {:ok,
     %{
       did: did,
       cid: head.cid,
       operation: head.operation,
       tombstoned: head.operation["type"] == "plc_tombstone",
       active_cids: state.chain |> Enum.reverse() |> Enum.map(& &1.cid),
       nullified_cids:
         Enum.filter([first | remaining], &MapSet.member?(state.nullified, &1.cid))
         |> Enum.map(& &1.cid)
     }}
  rescue
    _ in [MatchError, ArgumentError, KeyError, FunctionClauseError] -> {:error, :invalid_plc_log}
  catch
    :invalid -> {:error, :invalid_plc_log}
  end

  def verify(_, _), do: {:error, :invalid_plc_log}

  @doc "Derives a DID document exclusively from the verified surviving operation."
  def document(did, entries) do
    with {:ok, result} <- verify(did, entries) do
      if result.tombstoned,
        do: {:error, :did_not_found},
        else: {:ok, format_document(did, result.operation)}
    end
  end

  defp format_document(did, %{"type" => "create"} = op) do
    handle = op["handle"]

    handle =
      if String.starts_with?(handle, "at://"),
        do: handle,
        else:
          "at://" <>
            (handle
             |> String.replace_prefix("https://", "")
             |> String.replace_prefix("http://", ""))

    endpoint = op["service"]

    endpoint =
      if String.starts_with?(endpoint, ["https://", "http://"]),
        do: endpoint,
        else: "https://" <> endpoint

    format_document(did, %{
      "verificationMethods" => %{"atproto" => op["signingKey"]},
      "alsoKnownAs" => [handle],
      "services" => %{
        "atproto_pds" => %{"type" => "AtprotoPersonalDataServer", "endpoint" => endpoint}
      }
    })
  end

  defp format_document(did, op) do
    methods =
      op["verificationMethods"]
      |> Enum.sort()
      |> Enum.map(fn {id, "did:key:" <> key} ->
        %{
          "id" => did <> "#" <> id,
          "controller" => did,
          "type" => "Multikey",
          "publicKeyMultibase" => key
        }
      end)

    contexts =
      Enum.flat_map(methods, fn method ->
        case Atoll.Multikey.decode(method["publicKeyMultibase"]) do
          {:ok, %{curve: :p256}} -> ["https://w3id.org/security/suites/ecdsa-2019/v1"]
          {:ok, %{curve: :k256}} -> ["https://w3id.org/security/suites/secp256k1-2019/v1"]
          _ -> []
        end
      end)

    services =
      op["services"]
      |> Enum.sort()
      |> Enum.map(fn {id, service} ->
        %{"id" => "#" <> id, "type" => service["type"], "serviceEndpoint" => service["endpoint"]}
      end)

    %{
      "@context" =>
        Enum.uniq(
          ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"] ++ contexts
        ),
      "id" => did,
      "alsoKnownAs" => op["alsoKnownAs"],
      "verificationMethod" => methods,
      "service" => services
    }
  end

  defp entry!(
         %{
           "did" => did,
           "operation" => op,
           "cid" => cid,
           "nullified" => nullified,
           "createdAt" => timestamp
         },
         expected
       )
       when is_boolean(nullified) and is_binary(timestamp) and byte_size(timestamp) <= 64 do
    unless did == expected, do: throw(:invalid)
    {:ok, ^cid} = Operation.cid(op)
    {:ok, time, 0} = DateTime.from_iso8601(timestamp)
    %{operation: op, cid: cid, nullified: nullified, time: time}
  end

  defp entry!(_, _), do: throw(:invalid)

  defp advance!(entry, state) do
    if MapSet.member?(state.seen, entry.cid) or DateTime.compare(entry.time, state.latest) == :lt,
      do: throw(:invalid)

    {removed, retained} = Enum.split_while(state.chain, &(&1.cid != entry.operation["prev"]))
    [previous | _] = retained
    {:ok, signer} = Operation.verify_update(previous.operation, entry.operation)

    if removed != [] do
      first_removed = List.last(removed)

      {:ok, disputed_signer} =
        Operation.verify_update(previous.operation, first_removed.operation)

      keys = Operation.rotation_keys(previous.operation)

      unless Enum.find_index(keys, &(&1 == signer)) <
               Enum.find_index(keys, &(&1 == disputed_signer)) and
               DateTime.compare(entry.time, state.latest) == :gt and
               DateTime.diff(entry.time, first_removed.time, :microsecond) <= @window_us,
             do: throw(:invalid)
    end

    %{
      state
      | chain: [entry | retained],
        latest: entry.time,
        seen: MapSet.put(state.seen, entry.cid),
        nullified: Enum.reduce(removed, state.nullified, &MapSet.put(&2, &1.cid))
    }
  end
end
