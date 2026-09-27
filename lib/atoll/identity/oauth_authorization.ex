defmodule Atoll.Identity.OAuthAuthorization do
  @moduledoc "Current identity authorization with a head snapshot held under OAuth locks."
  def authenticate(%Atoll.OAuth.WriteCredential{} = credential, action) do
    Atoll.OAuth.Resource.recheck(credential, action, fn %{did: did} ->
      Atoll.Repo.get!(Atoll.Repositories.Head, did)
    end)
  end

  def authenticate(token, _action), do: Atoll.Accounts.Sessions.authenticate_management(token)
end
