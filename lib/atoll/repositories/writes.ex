defmodule Atoll.Repositories.Writes do
  @moduledoc "Authenticated single-record writes for repository DIDs. Lexicon validation is pending."
  import Ecto.Query
  alias Atoll.{CID, Repo, Repositories, Syntax, TID}
  alias Atoll.Accounts.{Sessions, Tokens}
  alias Atoll.Repositories.{Events, Head, Record}

  def write(token, action, body) when action in [:create, :put, :delete] and is_map(body) do
    with {:ok, claims} <- Tokens.verify(token, :access),
         :ok <- parameters(action, body),
         true <- body["repo"] == claims["sub"],
         {:ok, commit} <- swap(body, "swapCommit", false),
         {:ok, record} <- record_swap(action, body) do
      Repo.transaction(fn ->
        Events.lock!()
        did = claims["sub"]
        # Lock the head for writing before holding a session share lock.
        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:invalid_token)

        case Sessions.authenticate(token) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        rkey =
          case Map.fetch(body, "rkey") do
            {:ok, value} ->
              value

            :error ->
              {:ok, value} = TID.next(head.rev)
              value
          end

        path = body["collection"] <> "/" <> rkey

        prior =
          Repo.one(from r in Record, where: r.did == ^did and r.path == ^path, select: r.cid)

        if record != :any and record != prior, do: Repo.rollback(:invalid_swap)

        operation =
          if action == :delete, do: {:delete, path}, else: {action, path, body["record"]}

        case Repositories.apply_managed_writes(did, [operation], swap_commit: commit) do
          {:ok, updated} ->
            result = %{commit: %{cid: CID.to_base32(updated.head), rev: updated.rev}}

            if action == :delete do
              result
            else
              current = Repo.get_by!(Record, did: did, path: path)

              Map.merge(result, %{
                uri: "at://" <> did <> "/" <> path,
                cid: CID.to_base32(current.cid),
                validationStatus: "unknown"
              })
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def write(_, _, _), do: {:error, :invalid_request}

  defp parameters(action, body) do
    collection = body["collection"]

    valid_key =
      if action == :create and not Map.has_key?(body, "rkey"),
        do: true,
        else: Syntax.record_key?(body["rkey"])

    valid_record =
      action == :delete or (is_map(body["record"]) and body["record"]["$type"] == collection)

    cond do
      not (Syntax.did?(body["repo"]) and is_binary(collection) and
             Syntax.repo_path?(collection <> "/self") and valid_key and valid_record) ->
        {:error, :invalid_request}

      action != :delete and Map.get(body, "validate", false) == true ->
        {:error, :validation_unavailable}

      action != :delete and Map.get(body, "validate", false) != false ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp record_swap(:create, _), do: {:ok, :any}
  defp record_swap(action, body), do: swap(body, "swapRecord", action == :put)

  defp swap(body, field, nullable) do
    case Map.fetch(body, field) do
      :error ->
        {:ok, :any}

      {:ok, nil} when nullable ->
        {:ok, nil}

      {:ok, value} ->
        with {:ok, cid} <- CID.from_base32(value),
             {:ok, %{codec: :dag_cbor}} <- CID.decode(cid),
             do: {:ok, cid},
             else: (_ -> {:error, :invalid_request})
    end
  end
end
