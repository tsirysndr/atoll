defmodule Atoll.Accounts.SubjectStatus do
  @moduledoc "Operator account takedowns, retaining the underlying availability state."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Repositories.{Events, Head}
  @repo_type "com.atproto.admin.defs#repoRef"

  def get(%{"did" => did} = params) when map_size(params) == 1 do
    if Syntax.did?(did) do
      case Repo.get(Head, did) do
        nil -> {:error, :subject_not_found}
        head -> {:ok, view(head)}
      end
    else
      {:error, :invalid_request}
    end
  end

  def get(_), do: {:error, :unsupported_moderation_subject}

  def update(%{"subject" => %{"$type" => @repo_type, "did" => did} = subject} = params) do
    if Syntax.did?(did) and Map.keys(subject) -- ["$type", "did"] == [] and
         Map.keys(params) -- ["subject", "takedown", "deactivated"] == [] and
         attribute?(params, "takedown") and attribute?(params, "deactivated") and
         not (get_in(params, ["takedown", "applied"]) == true and
                get_in(params, ["deactivated", "applied"]) == false) do
      change(did, params)
    else
      {:error, :invalid_request}
    end
  end

  def update(_), do: {:error, :unsupported_moderation_subject}

  defp change(did, params) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      Events.lock!()

      head =
        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
          Repo.rollback(:subject_not_found)

      underlying = head.pre_takedown_status || head.status

      underlying =
        case Map.fetch(params, "deactivated") do
          :error -> underlying
          {:ok, _} when underlying == :suspended -> Repo.rollback(:invalid_request)
          {:ok, %{"applied" => true}} -> :deactivated
          {:ok, %{"applied" => false}} -> :active
        end

      {taken_down?, ref} =
        case Map.fetch(params, "takedown") do
          :error -> {head.status == :takendown, head.takedown_ref}
          {:ok, %{"applied" => true} = attr} -> {true, attr["ref"]}
          {:ok, %{"applied" => false}} -> {false, nil}
        end

      attrs = %{
        status: if(taken_down?, do: :takendown, else: underlying),
        pre_takedown_status: if(taken_down?, do: underlying),
        takedown_ref: ref
      }

      updated = head |> Ecto.Changeset.change(attrs) |> Repo.update!(log: false)

      # Private references and underlying states never enter public event payloads.
      if head.status != updated.status do
        Events.append!(:account, updated, %{
          "active" => updated.status == :active,
          "status" => Atom.to_string(updated.status)
        })
      end

      Map.take(view(updated), [:subject, :takedown])
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp view(head) do
    takedown = %{applied: head.status == :takendown}

    takedown =
      if head.takedown_ref, do: Map.put(takedown, :ref, head.takedown_ref), else: takedown

    %{
      subject: %{"$type" => @repo_type, "did" => head.did},
      takedown: takedown,
      deactivated: %{applied: (head.pre_takedown_status || head.status) == :deactivated}
    }
  end

  defp attribute?(params, key) do
    case Map.fetch(params, key) do
      :error ->
        true

      {:ok, %{"applied" => applied} = attr} ->
        is_boolean(applied) and Map.keys(attr) -- ["applied", "ref"] == [] and
          reference?(attr)

      _ ->
        false
    end
  end

  defp reference?(attr) do
    case Map.fetch(attr, "ref") do
      :error ->
        true

      {:ok, ref} when is_binary(ref) ->
        byte_size(ref) <= 2000 and String.valid?(ref) and not String.contains?(ref, <<0>>)

      _ ->
        false
    end
  end
end
