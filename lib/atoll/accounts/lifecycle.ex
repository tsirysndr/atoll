defmodule Atoll.Accounts.Lifecycle do
  @moduledoc "Authenticated activation and deactivation, serialized with repository mutations."
  import Ecto.Query
  alias Atoll.{KeyVault, Repo, Repositories}
  alias Atoll.Accounts.Sessions
  alias Atoll.Repositories.{Events, Head}

  def deactivate(token, params) when is_map(params) do
    with :ok <- deletion_hint(params),
         {:ok, head} <- Sessions.authenticate_management(token) do
      transition(token, head.did, :deactivated, nil)
    end
  end

  def deactivate(_, _), do: {:error, :invalid_request}

  def activate(token) do
    opts = Application.get_env(:atoll, :identity_resolution_options, [])

    with {:ok, head} <- Sessions.authenticate_management(token),
         {:ok, identity} <-
           Atoll.Identity.Resolver.resolve(head.did, Keyword.put(opts, :force_refresh, true)) do
      transition(token, head.did, :active, identity)
    else
      {:error, {:repo_inactive, _}} = error ->
        error

      {:error, reason}
      when reason in [
             :auth_required,
             :invalid_token,
             :expired_token,
             :session_configuration_missing
           ] ->
        {:error, reason}

      _ ->
        {:error, :identity_unavailable}
    end
  end

  defp transition(token, did, status, identity) do
    Repo.transaction(fn ->
      Events.lock!()

      head =
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
          Repo.rollback(:invalid_token)

      case Sessions.authenticate_management(token) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if status == :active do
        unless identity.signing_key == %{curve: head.curve, public: head.public_key} and
                 identity.pds == AtollWeb.Endpoint.url(),
               do: Repo.rollback(:identity_unavailable)

        case KeyVault.fetch(did) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        Repo.update_all(from(p in Atoll.Accounts.Profile, where: p.did == ^did),
          set: [import_curve: nil, import_public_key: nil, import_head: nil, import_rev: nil]
        )
      end

      case Repositories.set_status(did, status) do
        {:ok, updated} -> updated
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The protocol defines deleteAfter as a recommendation, not a deletion promise.
  # Retention remains indefinite until an explicit deletion/retention policy is implemented.
  defp deletion_hint(params) do
    case Map.fetch(params, "deleteAfter") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and byte_size(value) <= 64 ->
        case DateTime.from_iso8601(value) do
          {:ok, _, _} -> :ok
          _ -> {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end
end
