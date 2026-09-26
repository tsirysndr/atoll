defmodule Atoll.Accounts.AdminMessage do
  @moduledoc "Operator messages through the configured email Worker, with durable attempt history."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{EmailAddress, Profile}
  alias Atoll.Moderation.Audit
  alias Atoll.Repositories.{Events, Head}

  def deliver(params) when is_map(params) do
    with :ok <- validate(params),
         {:ok, {email, id}} <- prepare(params) do
      result =
        Atoll.Email.deliver(
          %{
            to: email,
            subject: Map.get(params, "subject", "Message from your PDS operator"),
            text: params["content"]
          },
          id,
          Application.get_env(:atoll, :email_delivery_options, [])
        )

      outcome =
        case result do
          :ok -> "accepted"
          {:error, :email_not_configured} -> "not_configured"
          {:error, :email_delivery_rejected} -> "rejected"
          _ -> "unavailable"
        end

      with {:ok, _} <-
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL lock_timeout = '1s'")
               Repo.query!("SET LOCAL statement_timeout = '5s'")
               Audit.email_delivery!(params, id, "prepared", outcome)
             end) do
        case result do
          :ok -> {:ok, %{sent: true}}
          error -> error
        end
      end
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def deliver(_), do: {:error, :invalid_request}

  defp prepare(params) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()
      did = params["recipientDid"]

      unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE"),
        do: Repo.rollback(:admin_account_not_found)

      profile =
        Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR SHARE"), log: false) ||
          Repo.rollback(:admin_account_not_found)

      email =
        case EmailAddress.normalize(profile.email) do
          {:ok, email} -> email
          _ -> Repo.rollback(:invalid_email)
        end

      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      Audit.email_delivery!(params, id, "absent", "prepared")
      {email, id}
    end)
  end

  defp validate(params) do
    allowed = ~w(recipientDid content subject senderDid comment)

    if Enum.all?(Map.keys(params), &(&1 in allowed)) and
         Syntax.did?(params["recipientDid"]) and Syntax.did?(params["senderDid"]) and
         text?(params["content"], 1, 12_000) and
         (not Map.has_key?(params, "subject") or subject?(params["subject"])) and
         (not Map.has_key?(params, "comment") or text?(params["comment"], 0, 2000)),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp text?(value, min, max),
    do:
      is_binary(value) and byte_size(value) >= min and byte_size(value) <= max and
        String.valid?(value)

  defp subject?(value),
    do: text?(value, 1, 200) and not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)
end
