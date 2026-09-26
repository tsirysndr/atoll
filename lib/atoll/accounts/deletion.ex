defmodule Atoll.Accounts.Deletion do
  @moduledoc "Owner and operator account deletion with atomic withdrawal and durable blob cleanup."
  import Ecto.Query
  alias Atoll.Accounts.{Credentials, Profile, Sessions}
  alias Atoll.Blobs.{Blob, Cleanup}
  alias Atoll.Repositories.{Event, Events, Head}
  alias Atoll.Repo

  def request(token) do
    with {:ok, {email, code}} <- prepare(token) do
      message = %{
        to: email,
        subject: "Delete your Atoll account",
        text:
          "Your Atoll account deletion code is: #{code}\n\nThis code expires in 15 minutes. Deletion removes the account from this server. If you did not request deletion, do not share this code."
      }

      case Atoll.Email.deliver(
             message,
             Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
             Application.get_env(:atoll, :email_delivery_options, [])
           ) do
        :ok -> {:ok, :sent}
        error -> error
      end
    end
  end

  defp prepare(token) do
    Repo.transaction(fn ->
      head =
        case Sessions.authenticate_status(token) do
          {:ok, head} -> head
          {:error, reason} -> Repo.rollback(reason)
        end

      profile = profile!(head.did)
      if is_nil(profile.email), do: Repo.rollback(:invalid_email)
      now = System.system_time(:second)

      if profile.deletion_requested_at && now - profile.deletion_requested_at < 60,
        do: Repo.rollback(:email_rate_limited)

      code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      profile
      |> Ecto.Changeset.change(
        deletion_digest: digest(profile, code),
        deletion_expires_at: now + 900,
        deletion_requested_at: now
      )
      |> Repo.update!(log: false)

      {profile.email, code}
    end)
  end

  def delete(%{"did" => did, "password" => password, "token" => code} = params)
      when is_binary(code) and byte_size(code) == 32 and map_size(params) == 3 do
    # Only the account password is accepted, never an app password.
    with {:ok, credential_digest} <- Credentials.verified_digest(did, password) do
      Repo.transaction(fn ->
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:invalid_credentials)

        unless Credentials.current_digest?(did, credential_digest),
          do: Repo.rollback(:invalid_credentials)

        profile = profile!(did)

        cond do
          is_nil(profile.deletion_digest) ->
            Repo.rollback(:invalid_email_token)

          not Plug.Crypto.secure_compare(profile.deletion_digest, digest(profile, code)) ->
            Repo.rollback(:invalid_email_token)

          profile.deletion_expires_at <= System.system_time(:second) ->
            Repo.rollback(:expired_email_token)

          true ->
            :ok
        end

        remove!(head)
      end)
    end
  end

  def delete(_), do: {:error, :invalid_request}

  @doc "Trusted operator deletion. HTTP callers must enforce operator authentication."
  def admin_delete(params, actor \\ "admin")

  def admin_delete(%{"did" => did} = params, actor)
      when map_size(params) == 1 and actor in ["admin", "operator", "system"] do
    if Atoll.Syntax.did?(did) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:admin_account_not_found)

        Atoll.Moderation.Audit.account_deletion!(head, actor)
        remove!(head)
      end)
    else
      {:error, :invalid_request}
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def admin_delete(_, _), do: {:error, :invalid_request}

  # Both authorization paths hold the event lock and an exclusive head lock.
  defp remove!(head) do
    did = head.did
    # Queue physical bytes before the FK cascade withdraws this account's ownership.
    Repo.stream(from(b in Blob, where: b.did == ^did), max_rows: 500)
    |> Stream.chunk_every(500)
    |> Enum.each(&Cleanup.enqueue!/1)

    # Old events must not become visible if this DID is provisioned again later.
    Repo.delete_all(from(e in Event, where: e.did == ^did))
    Repo.delete!(head)
    Events.append!(:account, head, %{"active" => false, "status" => "deleted"})
    :deleted
  end

  defp profile!(did),
    do:
      Repo.one(from(p in Profile, where: p.did == ^did, lock: "FOR UPDATE"), log: false) ||
        Repo.rollback(:account_not_found)

  defp digest(profile, code),
    do:
      :crypto.hash(:sha256, [
        "atoll.account-delete.v1",
        <<0>>,
        profile.did,
        <<0>>,
        profile.email || "",
        <<0>>,
        code
      ])
end
