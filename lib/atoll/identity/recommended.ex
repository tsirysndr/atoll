defmodule Atoll.Identity.Recommended do
  @moduledoc "Account signing key and PDS service metadata for a migrating DID document."
  alias Atoll.{KeyVault, Multikey, Repo}
  alias Atoll.Accounts.{Profile, Sessions}

  def get(token) do
    Repo.transaction(fn ->
      with {:ok, head} <- Sessions.authenticate_management(token),
           {:ok, key} <- KeyVault.fetch(head.did),
           {:ok, encoded} <- Multikey.to_did_key(key.curve, key.public) do
        profile = Repo.get(Profile, head.did)
        observation = Repo.get(Atoll.Identity.Observation, head.did)
        handle = if observation, do: observation.handle, else: profile && profile.handle

        result = %{
          verificationMethods: %{atproto: encoded},
          services: %{
            atproto_pds: %{type: "AtprotoPersonalDataServer", endpoint: AtollWeb.Endpoint.url()}
          }
        }

        if is_binary(handle) and handle != "handle.invalid",
          do: Map.put(result, :alsoKnownAs, ["at://" <> handle]),
          else: result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
