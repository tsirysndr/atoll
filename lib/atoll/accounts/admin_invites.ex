defmodule Atoll.Accounts.AdminInvites do
  @moduledoc "Transactional audit boundary for operator invite API actions. Authorization is required by the caller."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{Invite, Invites}
  alias Atoll.Moderation.Audit
  alias Atoll.Repositories.Events

  def create(%{"useCount" => uses} = params) do
    if Map.keys(params) -- ["useCount", "forAccount"] == [] do
      transaction(fn ->
        result = unwrap!(Invites.create(uses, params["forAccount"]))

        Audit.invite_codes!(
          "com.atproto.server.createInviteCode",
          result.forAccount,
          params,
          %{},
          %{created: 1, codeDigests: [fingerprint(result.code)]}
        )

        result
      end)
    else
      {:error, :invalid_request}
    end
  end

  def create(_), do: {:error, :invalid_request}

  def create_many(params) do
    transaction(fn ->
      result = unwrap!(Invites.create_many(params))

      groups =
        Enum.map(result, fn group ->
          %{account: group.account, codeDigests: Enum.map(group.codes, &fingerprint/1)}
        end)

      Audit.invite_codes!("com.atproto.server.createInviteCodes", nil, params, %{}, %{
        created: Enum.sum(Enum.map(result, &length(&1.codes))),
        groups: groups
      })

      result
    end)
  end

  def disable(params) when is_map(params) do
    codes = Map.get(params, "codes", [])
    accounts = Map.get(params, "accounts", [])

    if Map.keys(params) -- ["codes", "accounts"] == [] and
         is_list(codes) and length(codes) <= 100 and Enum.all?(codes, &code?/1) and
         is_list(accounts) and length(accounts) <= 100 and Enum.all?(accounts, &Syntax.did?/1) do
      transaction(fn ->
        query = from i in Invite, where: i.code in ^codes or i.for_account in ^accounts
        matched = Repo.aggregate(query, :count, :code, log: false)

        enabled =
          Repo.aggregate(from(i in query, where: not i.disabled), :count, :code, log: false)

        count = unwrap!(Invites.disable_many(params))

        requested = %{
          accounts: Enum.uniq(accounts),
          codeDigests: Enum.map(Enum.uniq(codes), &fingerprint/1)
        }

        Audit.invite_codes!(
          "com.atproto.admin.disableInviteCodes",
          nil,
          requested,
          %{matched: matched, enabled: enabled, disabled: matched - enabled},
          %{matched: count, enabled: 0, disabled: count}
        )

        count
      end)
    else
      {:error, :invalid_request}
    end
  end

  def disable(_), do: {:error, :invalid_request}

  defp transaction(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()
      fun.()
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp fingerprint(code), do: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower)

  defp code?(value),
    do:
      is_binary(value) and byte_size(value) == 32 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)
end
