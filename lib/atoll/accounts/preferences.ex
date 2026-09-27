defmodule Atoll.Accounts.Preferences do
  @moduledoc """
  Private `app.bsky` actor preferences attached to an account.

  Preferences never enter the signed repository or the firehose. Reads and
  writes replace only the `app.bsky` namespace; restricted sessions can neither
  read nor replace personal details, and the declared-age preference is derived
  from a stored birth date rather than stored directly.
  """
  import Ecto.Query
  alias Atoll.Accounts.{Preference, Sessions}
  alias Atoll.Repo

  @namespace "app.bsky"
  @full_access_only ["app.bsky.actor.defs#personalDetailsPref"]
  @read_only ["app.bsky.actor.defs#declaredAgePref"]
  @get_method "app.bsky.actor.getPreferences"

  def get(token) do
    Repo.transaction(fn ->
      # Reads stay available during takedown so owners can export preferences.
      case Sessions.authenticate_owner_export(token) do
        {:ok, session} ->
          %{preferences: read(session.did, session.scope == "com.atproto.access")}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc "OAuth read inside resource authorization locks; OAuth grants never include personal details."
  def oauth_get(principal) do
    if Atoll.OAuth.Permissions.allows_preferences?(principal.scope, @get_method),
      do: {:ok, %{preferences: read(principal.did, false)}},
      else: {:error, :insufficient_scope}
  end

  def put(%Atoll.OAuth.WriteCredential{} = credential, body) do
    with {:ok, values} <- values(body) do
      Atoll.OAuth.Resource.recheck(credential, :put_preferences, fn principal ->
        case store(principal.did, values, false) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def put(token, body) do
    with {:ok, values} <- values(body) do
      Repo.transaction(fn ->
        with {:ok, session} <- Sessions.authenticate_session(token),
             {:ok, result} <- store(session.did, values, session.scope == "com.atproto.access") do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp read(did, full?) do
    stored =
      case Repo.get(Preference, did) do
        nil -> []
        row -> row.preferences
      end

    preferences = Enum.filter(stored, &namespaced?/1)

    (preferences ++ declared_age(preferences))
    |> Enum.filter(fn preference -> full? or preference["$type"] not in @full_access_only end)
  end

  defp store(did, values, full?) do
    if full? or not Enum.any?(values, &(&1["$type"] in @full_access_only)) do
      row =
        Repo.one(from(p in Preference, where: p.did == ^did, lock: "FOR UPDATE"), log: false) ||
          %Preference{did: did, preferences: []}

      kept =
        Enum.filter(row.preferences, fn preference ->
          not namespaced?(preference) or (not full? and preference["$type"] in @full_access_only)
        end)

      incoming = Enum.reject(values, &(&1["$type"] in @read_only))

      row
      |> Ecto.Changeset.change(preferences: kept ++ incoming)
      |> Repo.insert_or_update!(log: false)

      {:ok, :updated}
    else
      {:error, :invalid_request}
    end
  end

  defp values(%{"preferences" => values}) when is_list(values) and length(values) <= 1000 do
    if Enum.all?(values, fn value ->
         is_map(value) and not is_struct(value) and is_binary(value["$type"]) and
           byte_size(value["$type"]) <= 1024 and namespaced?(value)
       end),
       do: {:ok, values},
       else: {:error, :invalid_request}
  end

  defp values(_), do: {:error, :invalid_request}

  defp namespaced?(%{"$type" => type}) when is_binary(type),
    do: type == @namespace or String.starts_with?(type, @namespace <> ".")

  defp namespaced?(_), do: false

  defp declared_age(preferences) do
    with %{"birthDate" => birth} <-
           Enum.find(preferences, &(&1["$type"] in @full_access_only)),
         true <- is_binary(birth),
         {:ok, birthday, _} <- DateTime.from_iso8601(birth) do
      age = age(DateTime.to_date(birthday), Date.utc_today())

      [
        %{
          "$type" => "app.bsky.actor.defs#declaredAgePref",
          "isOverAge13" => age >= 13,
          "isOverAge16" => age >= 16,
          "isOverAge18" => age >= 18
        }
      ]
    else
      _ -> []
    end
  end

  defp age(birthday, today) do
    years = today.year - birthday.year
    if {today.month, today.day} < {birthday.month, birthday.day}, do: years - 1, else: years
  end
end
