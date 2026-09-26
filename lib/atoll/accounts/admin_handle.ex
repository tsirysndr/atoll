defmodule Atoll.Accounts.AdminHandle do
  @moduledoc "Operator handle changes through the verified owner workflow; caller must authenticate separately."
  def update(params, opts \\ [])

  def update(%{"did" => did, "handle" => handle} = params, opts) when map_size(params) == 2 do
    result =
      if Atoll.Syntax.did?(did),
        do: Atoll.Identity.HandleChanges.update({:admin, did}, %{"handle" => handle}, opts),
        else: {:error, :invalid_request}

    case result do
      {:error, reason}
      when reason in [
             :did_not_found,
             :resolution_failed,
             :unsafe_destination,
             :invalid_did_document,
             :invalid_did,
             :unsupported_did_method,
             :did_document_too_large,
             :stale_identity_refresh
           ] ->
        {:error, :identity_unavailable}

      result ->
        result
    end
  end

  def update(_, _), do: {:error, :invalid_request}
end
