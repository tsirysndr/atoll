defmodule Atoll.Accounts.Authenticator do
  @moduledoc """
  Internal owner-authorized authenticator enrollment and durable login admission.
  Enrollment requires a live full-account JWT and fresh password. Login callers
  must first prove the password, then pass check_login's result only as trusted
  server state into session creation. No HTTP caller may supply that result.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Credentials, Sessions, TOTP, TOTPSecret, TOTPFactor}
  alias Atoll.Repositories.Head

  def begin(token, password) do
    with {:ok, head} <- Sessions.authenticate_management(token),
         {:ok, digest} <- Credentials.verified_digest(head.did, password),
         secret = TOTP.generate_secret(),
         {:ok, envelope} <- TOTPSecret.seal(head.did, secret) do
      transact(fn ->
        owner!(token, head.did, digest)
        row = factor(head.did)
        if row && row.confirmed_at, do: Repo.rollback(:totp_already_enabled)
        now = clock!()

        attrs = %{
          version: random(),
          envelope: envelope,
          credential_digest: digest,
          pending_expires_at: now + 600,
          confirmed_at: nil,
          last_used_step: -1,
          recovery_hashes: []
        }

        row = row || %TOTPFactor{did: head.did}
        row |> Ecto.Changeset.change(attrs) |> Repo.insert_or_update!(log: false)
        {:ok, %{secret: Base.encode32(secret, padding: false), expires_at: now + 600}}
      end)
    end
  end

  def confirm(token, code) do
    with {:ok, head} <- Sessions.authenticate_management(token) do
      transact(fn ->
        owner!(token, head.did, nil)
        row = factor(head.did) || Repo.rollback(:totp_not_enrolled)
        now = clock!()
        if row.confirmed_at, do: Repo.rollback(:totp_already_enabled)

        if row.pending_expires_at <= now or
             not Credentials.current_digest?(head.did, row.credential_digest),
           do: Repo.rollback(:totp_enrollment_expired)

        case consume(row, code, now) do
          {:ok, row} ->
            {codes, hashes} = recovery_codes(row.did)

            row
            |> Ecto.Changeset.change(
              confirmed_at: now,
              pending_expires_at: nil,
              recovery_hashes: hashes
            )
            |> Repo.update!(log: false)

            {:ok, %{recovery_codes: codes}}

          error ->
            error
        end
      end)
    end
  end

  @doc "Owner-only factor state; never returns a secret or recovery hash."
  def status(token) do
    with {:ok, head} <- Sessions.authenticate_management(token) do
      transact(fn ->
        owner!(token, head.did, nil)
        row = factor(head.did)

        state =
          cond do
            is_nil(row) -> :disabled
            row.confirmed_at -> :enabled
            row.pending_expires_at > clock!() -> :pending
            true -> :disabled
          end

        {:ok,
         %{state: state, recovery_remaining: if(row, do: length(row.recovery_hashes), else: 0)}}
      end)
    end
  end

  @doc "Disable TOTP with a full session, fresh password and a one-time factor proof."
  def disable(token, password, code), do: manage(token, password, code, :disable)

  @doc "Replace all recovery codes, displaying the new plaintext codes only once."
  def regenerate(token, password, code), do: manage(token, password, code, :regenerate)

  defp manage(token, password, code, action) do
    with {:ok, head} <- Sessions.authenticate_management(token),
         {:ok, digest} <- Credentials.verified_digest(head.did, password) do
      transact(fn ->
        owner!(token, head.did, digest)
        row = factor(head.did)
        if is_nil(row) or is_nil(row.confirmed_at), do: Repo.rollback(:totp_not_enrolled)

        case consume(row, code, clock!()) do
          {:ok, row} when action == :disable ->
            Repo.delete!(row, log: false)
            {:ok, :disabled}

          {:ok, row} ->
            {codes, hashes} = recovery_codes(row.did)

            row
            |> Ecto.Changeset.change(recovery_hashes: hashes, version: random())
            |> Repo.update!(log: false)

            {:ok, %{recovery_codes: codes}}

          error ->
            error
        end
      end)
    end
  end

  @doc "Standalone password-proved admission. Failed attempts and consumed steps commit even if later login fails."
  def check_login(did, digest, code) do
    transact(fn ->
      head = Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE")

      if is_nil(head) or head.status not in [:active, :deactivated, :takendown],
        do: Repo.rollback(:invalid_credentials)

      unless Credentials.current_digest?(did, digest), do: Repo.rollback(:invalid_credentials)
      row = factor(did)

      cond do
        is_nil(row) or is_nil(row.confirmed_at) ->
          {:ok, :disabled}

        is_nil(code) or code == "" ->
          {:error, :totp_required}

        true ->
          now = clock!()

          case consume(row, code, now) do
            {:ok, row} ->
              {:ok, %{version: row.version, step: row.last_used_step, expires_at: now + 30}}

            error ->
              error
          end
      end
    end)
  end

  @doc "Recheck trusted admission while session creation holds the account write lock."
  def recheck!(did, admission) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "TOTP recheck requires a transaction")
    row = factor(did)

    valid =
      case {row, admission} do
        {nil, :disabled} ->
          true

        {%{confirmed_at: nil}, :disabled} ->
          true

        {%{confirmed_at: confirmed, version: version, last_used_step: last},
         %{version: version, step: step, expires_at: expires}}
        when not is_nil(confirmed) ->
          is_integer(step) and step >= 0 and step <= last and is_integer(expires) and
            expires > clock!()

        _ ->
          false
      end

    unless valid, do: Repo.rollback(:totp_required)
    :ok
  end

  @doc false
  def rewrap!(did, master) do
    case factor(did) do
      nil ->
        :absent

      row ->
        case TOTPSecret.rewrap_to(did, row.envelope, master) do
          {:ok, :unchanged} ->
            :unchanged

          {:ok, envelope} ->
            row |> Ecto.Changeset.change(envelope: envelope) |> Repo.update!(log: false)
            :rotated

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  defp consume(row, code, now) do
    row =
      if now >= row.window_started_at + 300,
        do:
          row
          |> Ecto.Changeset.change(attempts: 0, window_started_at: now)
          |> Repo.update!(log: false),
        else: row

    cond do
      row.attempts >= 5 ->
        {:error, :totp_rate_limited}

      true ->
        case verify_factor(row, code, now) do
          {:ok, attrs} ->
            # All successful proofs count toward the same per-account attempt limit.
            updated =
              row
              |> Ecto.Changeset.change(Map.put(attrs, :attempts, row.attempts + 1))
              |> Repo.update!(log: false)

            {:ok, updated}

          {:error, :invalid_totp} ->
            row |> Ecto.Changeset.change(attempts: row.attempts + 1) |> Repo.update!(log: false)
            {:error, :invalid_totp}

          error ->
            error
        end
    end
  end

  # Recovery codes are 128 random bits; fast hashes are safe for this high-entropy input.
  defp recovery_codes(did) do
    codes = for _ <- 1..10, do: Base.encode32(:crypto.strong_rand_bytes(16), padding: false)
    {codes, Enum.map(codes, &recovery_hash(did, &1))}
  end

  defp recovery_hash(did, code),
    do: :crypto.hash(:sha256, ["atoll.totp-recovery.v1", <<0>>, did, <<0>>, code])

  defp verify_factor(%{confirmed_at: confirmed} = row, code, _now)
       when not is_nil(confirmed) and is_binary(code) and byte_size(code) == 26 do
    hash = recovery_hash(row.did, code)
    # Compare all candidates, then remove the matched hash while holding the factor lock.
    remaining = Enum.reject(row.recovery_hashes, &Plug.Crypto.secure_compare(&1, hash))

    if length(remaining) < length(row.recovery_hashes),
      do: {:ok, %{recovery_hashes: remaining}},
      else: {:error, :invalid_totp}
  end

  defp verify_factor(row, code, now) do
    with {:ok, secret} <- TOTPSecret.open(row.did, row.envelope),
         {:ok, step} <- TOTP.verify(secret, code, now, row.last_used_step),
         do: {:ok, %{last_used_step: step}}
  end

  defp owner!(token, did, digest) do
    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:invalid_token)

    case Sessions.authenticate_management(token) do
      {:ok, %{did: ^did}} -> :ok
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid_token)
    end

    if digest && not Credentials.current_digest?(did, digest),
      do: Repo.rollback(:invalid_credentials)
  end

  defp factor(did),
    do: Repo.one(from(f in TOTPFactor, where: f.did == ^did, lock: "FOR UPDATE"), log: false)

  defp clock! do
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
    now
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp transact(fun) do
    if Repo.in_transaction?() do
      {:error, :totp_inside_transaction}
    else
      case Repo.transaction(fn ->
             Repo.query!("SET LOCAL lock_timeout = '1s'")
             Repo.query!("SET LOCAL statement_timeout = '5s'")
             fun.()
           end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :totp_store_unavailable}
  end
end
