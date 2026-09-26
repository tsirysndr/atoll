defmodule Atoll.Repositories.Writes do
  @moduledoc "Authenticated writes for DIDs or bidirectionally verified handles. Includes validation against known record Lexicons."
  import Ecto.Query
  alias Atoll.{CID, Repo, Repositories, Syntax, TID}
  alias Atoll.Accounts.{Sessions, Tokens}
  alias Atoll.Repositories.{Events, Head, Record}
  @batch_type "com.atproto.repo.applyWrites#"

  def batch(token, body) when is_map(body) do
    with {:ok, claims} <- Tokens.verify(token, :access),
         :ok <- batch_parameters(body),
         {:ok, commit} <- swap(body, "swapCommit", false),
         {:ok, writes} <- batch_operations(body),
         {:ok, did} <- repository_did(body["repo"]),
         true <- did == claims["sub"] do
      Repo.transaction(fn ->
        did = claims["sub"]
        head = authorize!(token, did)
        if commit != :any and commit != head.head, do: Repo.rollback(:invalid_swap)

        {prepared, _} =
          Enum.map_reduce(writes, head.rev, fn {action, value, validation}, previous ->
            {rkey, previous} =
              case Map.fetch(value, "rkey") do
                {:ok, rkey} ->
                  {rkey, previous}

                :error ->
                  {:ok, rkey} = TID.next(previous)
                  {rkey, rkey}
              end

            path = value["collection"] <> "/" <> rkey

            if action == :update and
                 not Repo.exists?(from r in Record, where: r.did == ^did and r.path == ^path),
               do: Repo.rollback(:record_not_found)

            operation =
              case action do
                :delete -> {:delete, path}
                :update -> {:put, path, value["value"]}
                :create -> {:create, path, value["value"]}
              end

            {{action, path, operation, validation}, previous}
          end)

        updated =
          if prepared == [] do
            head
          else
            case Repositories.apply_managed_writes(did, Enum.map(prepared, &elem(&1, 2)),
                   swap_commit: commit
                 ) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          end

        results =
          Enum.map(prepared, fn {action, path, _, validation} ->
            result = %{"$type" => @batch_type <> Atom.to_string(action) <> "Result"}

            if action == :delete do
              result
            else
              current = Repo.get_by!(Record, did: did, path: path)

              Map.merge(result, %{
                "uri" => "at://" <> did <> "/" <> path,
                "cid" => CID.to_base32(current.cid),
                "validationStatus" => validation
              })
            end
          end)

        %{commit: %{cid: CID.to_base32(updated.head), rev: updated.rev}, results: results}
      end)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def batch(_, _), do: {:error, :invalid_request}

  defp batch_parameters(body) do
    cond do
      not repository_identifier?(body["repo"]) -> {:error, :invalid_request}
      not is_list(body["writes"]) or length(body["writes"]) > 200 -> {:error, :invalid_request}
      Map.get(body, "validate", false) not in [true, false] -> {:error, :invalid_request}
      true -> :ok
    end
  end

  defp batch_operations(body) do
    Enum.reduce_while(body["writes"], {:ok, []}, fn value, {:ok, acc} ->
      action =
        case value do
          %{"$type" => @batch_type <> "create"} -> :create
          %{"$type" => @batch_type <> "update"} -> :update
          %{"$type" => @batch_type <> "delete"} -> :delete
          _ -> nil
        end

      if action do
        params =
          value
          |> Map.take(["collection", "rkey"])
          |> Map.merge(%{"repo" => body["repo"], "record" => value["value"]})

        case parameters(if(action == :update, do: :put, else: action), params) do
          :ok ->
            params = Map.put(params, "validate", Map.get(body, "validate", :optimistic))

            case record_validation(action, params) do
              {:ok, status} -> {:cont, {:ok, [{action, value, status} | acc]}}
              error -> {:halt, error}
            end

          error ->
            {:halt, error}
        end
      else
        {:halt, {:error, :invalid_request}}
      end
    end)
    |> case do
      {:ok, writes} -> {:ok, Enum.reverse(writes)}
      error -> error
    end
  end

  defp authorize!(token, did) do
    Events.lock!()
    # Write-lock the head before locking the session, matching other authenticated writes.
    head =
      Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
        Repo.rollback(:invalid_token)

    case Sessions.authenticate(token) do
      {:ok, _} -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def write(token, action, body) when action in [:create, :put, :delete] and is_map(body) do
    with {:ok, claims} <- Tokens.verify(token, :access),
         :ok <- parameters(action, body),
         {:ok, validation} <- record_validation(action, body),
         {:ok, commit} <- swap(body, "swapCommit", false),
         {:ok, record} <- record_swap(action, body),
         {:ok, did} <- repository_did(body["repo"]),
         true <- did == claims["sub"] do
      Repo.transaction(fn ->
        did = claims["sub"]
        head = authorize!(token, did)

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
                validationStatus: validation
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
      not (repository_identifier?(body["repo"]) and is_binary(collection) and
             Syntax.repo_path?(collection <> "/self") and valid_key and valid_record) ->
        {:error, :invalid_request}

      action != :delete and Map.get(body, "validate", false) not in [true, false] ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp record_validation(:delete, _), do: {:ok, nil}

  defp record_validation(_, body) do
    Atoll.Lexicon.Schema.record(
      body["collection"],
      body["rkey"],
      body["record"],
      Map.get(body, "validate", :optimistic)
    )
  end

  defp record_swap(:create, _), do: {:ok, :any}
  defp record_swap(action, body), do: swap(body, "swapRecord", action == :put)

  defp repository_identifier?(value), do: Syntax.did?(value) or Syntax.handle?(value)

  defp repository_did(identifier) do
    if Syntax.did?(identifier) do
      {:ok, identifier}
    else
      # Resolve before opening the write transaction; recheck the live session under lock.
      opts =
        Application.get_env(:atoll, :identity_resolution_options, [])
        |> Keyword.put(:force_refresh, true)

      case Atoll.Identity.Handle.verify(identifier, opts) do
        {:ok, identity} -> {:ok, identity.did}
        {:error, _} -> {:error, :unverified_handle}
      end
    end
  end

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
