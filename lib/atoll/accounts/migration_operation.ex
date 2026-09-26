defmodule Atoll.Accounts.MigrationOperation do
  @moduledoc "Verifies a proposed migration successor before reserved custody or account creation changes."
  alias Atoll.Multikey
  alias Atoll.Identity.PLC.{Client, Operation}

  def prepare(%{operation: nil}, _, _), do: {:ok, nil}

  def prepare(%{did: "did:plc:" <> _ = did, operation: operation, handle: handle}, verified, opts) do
    with :ok <- Operation.validate_submission(operation),
         true <- operation["alsoKnownAs"] == ["at://" <> handle],
         true <-
           get_in(operation, ["services", "atproto_pds"]) == %{
             "type" => "AtprotoPersonalDataServer",
             "endpoint" => AtollWeb.Endpoint.url()
           },
         public when is_binary(public) <- get_in(operation, ["verificationMethods", "atproto"]),
         {:ok, %{curve: :k256}} <- Multikey.from_did_key(public),
         {:ok, %{entries: audit, state: %{tombstoned: false} = state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         {:ok, source} <-
           Multikey.to_did_key(verified.signing_key.curve, verified.signing_key.public),
         {:ok, predecessor} <- Operation.successor(state.operation),
         true <- get_in(predecessor, ["verificationMethods", "atproto"]) == source,
         {:ok, _} <- Operation.verify_update(state.operation, operation) do
      {:ok, %{audit: audit, public_key: public}}
    else
      {:error, :invalid_plc_operation} -> {:error, :invalid_request}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_request}
end
