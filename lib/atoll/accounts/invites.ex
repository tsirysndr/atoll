defmodule Atoll.Accounts.Invites do
  @moduledoc "Internal operator invite issuance and transactional signup redemption. Not an authorization boundary."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{Invite, InviteUse}
  alias Atoll.Repositories.{Events, Head}

  def required?, do: Application.get_env(:atoll, :invite_code_required, false)

  def create(use_count \\ 1, for_account \\ nil)

  def create(use_count, for_account) when is_integer(use_count) and use_count in 1..10_000 do
    if is_nil(for_account) or Syntax.did?(for_account) do
      Repo.transaction(fn ->
        Events.lock!()

        if for_account do
          unless Repo.one(from h in Head, where: h.did == ^for_account, lock: "FOR SHARE"),
            do: Repo.rollback(:account_not_found)
        end

        code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        Repo.insert!(
          %Invite{
            code: code,
            use_count: use_count,
            remaining: use_count,
            for_account: for_account
          },
          log: false
        )

        %{code: code, useCount: use_count, forAccount: for_account}
      end)
    else
      {:error, :invalid_request}
    end
  end

  def create(_, _), do: {:error, :invalid_request}

  def disable(code) do
    if valid_code?(code) do
      Repo.transaction(fn ->
        Events.lock!()

        {count, _} =
          Repo.update_all(
            from(i in Invite, where: i.code == ^code),
            [set: [disabled: true, updated_at: DateTime.utc_now()]],
            log: false
          )

        if count == 0, do: Repo.rollback(:invalid_invite_code)
        :disabled
      end)
    else
      {:error, :invalid_invite_code}
    end
  end

  @doc "Cheap preflight before password hashing; redemption rechecks under the write lock."
  def validate_new(nil), do: if(required?(), do: {:error, :invalid_invite_code}, else: :ok)

  def validate_new(code) do
    if valid_code?(code) do
      case Repo.get(Invite, code, log: false) do
        %{disabled: false, remaining: remaining} when remaining > 0 -> :ok
        _ -> {:error, :invalid_invite_code}
      end
    else
      {:error, :invalid_invite_code}
    end
  end

  @doc "Consumes a use within account provisioning, serialized with repository mutations."
  def consume!(did, code) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "invite redemption requires a transaction")

    Events.lock!()
    unless Syntax.did?(did), do: Repo.rollback(:invalid_request)

    unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE"),
      do: Repo.rollback(:account_not_found)

    case Repo.get(InviteUse, did, log: false) do
      %{code: ^code} -> :ok
      nil -> redeem!(did, code)
      _ -> Repo.rollback(:invalid_invite_code)
    end
  end

  @doc "Retries retain their original reservation, even after policy changes or code disabling."
  def retry?(did, code) do
    case Repo.get(InviteUse, did, log: false) do
      %{code: ^code} -> true
      nil -> is_nil(code)
      _ -> false
    end
  end

  defp redeem!(_did, nil) do
    case validate_new(nil) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp redeem!(did, code) do
    unless valid_code?(code), do: Repo.rollback(:invalid_invite_code)
    invite = Repo.one(from(i in Invite, where: i.code == ^code, lock: "FOR UPDATE"), log: false)

    unless invite && not invite.disabled && invite.remaining > 0,
      do: Repo.rollback(:invalid_invite_code)

    invite |> Ecto.Changeset.change(remaining: invite.remaining - 1) |> Repo.update!(log: false)
    Repo.insert!(%InviteUse{did: did, code: code}, log: false)
    :ok
  end

  defp valid_code?(code),
    do: is_binary(code) and byte_size(code) == 32 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, code)
end
