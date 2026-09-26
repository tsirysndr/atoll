defmodule Atoll.Accounts.AppPasswords do
  @moduledoc "Revocable random application credentials; only their digests are retained."
  import Ecto.Query
  alias Atoll.Accounts.{AppPassword, Sessions, Tokens}
  alias Atoll.Repositories.Head
  alias Atoll.Repo

  def create(token, %{"name" => name} = params) do
    privileged = Map.get(params, "privileged", false)

    if valid_name?(name) and is_boolean(privileged) and
         Map.keys(params) -- ["name", "privileged"] == [] do
      Repo.transaction(fn ->
        did = authorize!(token)

        if Repo.aggregate(from(a in AppPassword, where: a.did == ^did), :count) >= 100,
          do: Repo.rollback(:app_password_limit)

        password =
          :crypto.strong_rand_bytes(20)
          |> Base.encode32(case: :lower, padding: false)
          |> String.graphemes()
          |> Enum.chunk_every(4)
          |> Enum.map_join("-", &Enum.join/1)

        changeset =
          Ecto.Changeset.change(%AppPassword{
            did: did,
            name: name,
            privileged: privileged,
            digest: digest(did, password)
          })
          |> Ecto.Changeset.unique_constraint([:did, :name])

        case Repo.insert(changeset, log: false) do
          {:ok, app} -> Map.put(public(app), :password, password)
          {:error, _} -> Repo.rollback(:app_password_exists)
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  def create(_, _), do: {:error, :invalid_request}

  def list(token) do
    Repo.transaction(fn ->
      case Sessions.authenticate_management(token) do
        {:ok, head} ->
          %{
            passwords:
              Repo.all(
                from a in AppPassword,
                  where: a.did == ^head.did,
                  order_by: [asc: a.inserted_at, asc: a.name]
              )
              |> Enum.map(&public/1)
          }

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def revoke(token, %{"name" => name} = params) when map_size(params) == 1 do
    if valid_name?(name) do
      Repo.transaction(fn ->
        did = authorize!(token)
        # The foreign key cascades revocation to every session created with this credential.
        Repo.delete_all(from(a in AppPassword, where: a.did == ^did and a.name == ^name),
          log: false
        )

        :revoked
      end)
    else
      {:error, :invalid_request}
    end
  end

  def revoke(_, _), do: {:error, :invalid_request}

  @doc false
  def verify(did, password) when is_binary(password) and byte_size(password) in 8..1024 do
    case Repo.get_by(AppPassword, [did: did, digest: digest(did, password)], log: false) do
      nil -> {:error, :invalid_credentials}
      app -> {:ok, %{id: app.id, scope: scope(app)}}
    end
  end

  def verify(_, _), do: {:error, :invalid_credentials}

  @doc false
  def current?(did, id, scope) do
    case Repo.get(AppPassword, id) do
      %AppPassword{did: ^did} = app -> scope(app) == scope
      _ -> false
    end
  end

  defp authorize!(token) do
    with {:ok, claims} <- Tokens.verify(token, :access) do
      Repo.one(from h in Head, where: h.did == ^claims["sub"], lock: "FOR UPDATE") ||
        Repo.rollback(:invalid_token)

      case Sessions.authenticate_management(token) do
        {:ok, head} -> head.did
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp scope(%{privileged: true}), do: "com.atproto.appPassPrivileged"
  defp scope(_), do: "com.atproto.appPass"

  defp digest(did, password),
    do: :crypto.hash(:sha256, ["atoll.app-password.v1", <<0>>, did, <<0>>, password])

  defp public(app),
    do: %{
      name: app.name,
      privileged: app.privileged,
      createdAt: DateTime.to_iso8601(app.inserted_at)
    }

  defp valid_name?(value) when is_binary(value) and byte_size(value) in 1..128,
    do:
      String.valid?(value) and String.trim(value) != "" and
        not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)

  defp valid_name?(_), do: false
end
