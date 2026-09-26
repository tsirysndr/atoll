defmodule Atoll.Identity.PLC.Signing do
  @moduledoc "Email-authorized PLC signing without directory submission or local identity mutation."
  import Ecto.Query
  alias Atoll.{Multikey, Repo}
  alias Atoll.Identity.PLC.{Client, Operation, Registrations, SignatureChallenges, Update}
  alias Atoll.Repositories.{Events, Head}
  @fields ~w(rotationKeys alsoKnownAs verificationMethods services)

  def sign(token, params, opts \\ []) do
    cond do
      Repo.in_transaction?() ->
        {:error, :plc_update_inside_transaction}

      not is_map(params) or Map.keys(params) -- ["token" | @fields] != [] ->
        {:error, :invalid_request}

      true ->
        prepare(token, params, opts)
    end
  end

  defp prepare(token, params, opts) do
    with {:ok, did} <- SignatureChallenges.verify(token, params["token"]),
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         {:ok, successor} <- Operation.successor(state.operation) do
      unsigned = Map.merge(successor, Map.take(params, @fields))

      Repo.transaction(fn ->
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        ^did = SignatureChallenges.consume!(token, params["token"])

        if Repo.exists?(
             from u in Update,
               where: u.did == ^did and is_nil(u.completed_at) and is_nil(u.nullified_at)
           ),
           do: Repo.rollback(:plc_update_pending)

        {:ok, local_key} = Multikey.to_did_key(head.curve, head.public_key)

        unless get_in(successor, ["verificationMethods", "atproto"]) == local_key and
                 get_in(successor, ["services", "atproto_pds", "endpoint"]) ==
                   AtollWeb.Endpoint.url(),
               do: Repo.rollback(:invalid_handle_update)

        rotation = unwrap!(Registrations.rotation_key(did))

        operation =
          case Operation.sign(unsigned, rotation) do
            {:ok, op} -> op
            _ -> Repo.rollback(:invalid_request)
          end

        case Operation.verify_update(state.operation, operation) do
          {:ok, _} -> %{operation: operation}
          _ -> Repo.rollback(:invalid_plc_operation)
        end
      end)
    end
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
