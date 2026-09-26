defmodule Atoll.Identity.HandleAuthorization do
  @moduledoc "Internal handle workflow authorization. Operator tuples must originate behind AdminAuth."
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{Sessions, Signup}
  alias Atoll.Repositories.Head

  def authenticate({:admin, did}) do
    if Syntax.did?(did) do
      case Repo.get(Head, did) do
        nil -> {:error, :admin_account_not_found}
        head -> {:ok, head}
      end
    else
      {:error, :invalid_request}
    end
  end

  def authenticate(token), do: Sessions.authenticate_management(token)

  # Operators may repair inactive accounts without changing their availability.
  # Pending signup genesis must stay consistent with the reserved identity.
  def allowed({:admin, did}, %{did: did}) do
    if Signup.pending?(did), do: {:error, :plc_update_pending}, else: :ok
  end

  def allowed(_, %{status: :active}), do: :ok
  def allowed(_, %{status: status}), do: {:error, {:repo_inactive, status}}

  def audit!({:admin, did}, %{did: did} = profile, handle),
    do: Atoll.Moderation.Audit.handle_change!(profile, handle)

  def audit!(_, _, _), do: :ok
end
