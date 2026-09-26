defmodule Atoll.Accounts.AdminSearch do
  @moduledoc "Operator-only account search with exact normalized email filtering and DID keyset pagination."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.{AdminInfo, EmailAddress, Profile}
  alias Atoll.Repositories.Head

  def search(params) when is_map(params) do
    with true <- Map.keys(params) -- ["email", "limit", "cursor"] == [],
         {:ok, email} <- email(params["email"]),
         {:ok, limit} <- page_size(params["limit"]),
         {:ok, cursor} <- cursor(params["cursor"], email) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")

        query =
          from p in Profile,
            join: h in Head,
            on: h.did == p.did,
            order_by: p.did,
            limit: ^(limit + 1),
            select: p

        query = if email, do: where(query, [p], p.email == ^email), else: query
        query = if cursor, do: where(query, [p], p.did > ^cursor), else: query
        rows = Repo.all(query, log: false)
        page = Enum.take(rows, limit)
        result = %{accounts: Enum.map(page, &AdminInfo.summary/1)}

        if length(rows) > limit,
          do: Map.put(result, :cursor, encode_cursor(List.last(page).did, email)),
          else: result
      end)
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(error, __STACKTRACE__)

    DBConnection.ConnectionError ->
      {:error, :admin_busy}
  end

  def search(_), do: {:error, :invalid_request}
  defp email(nil), do: {:ok, nil}
  defp email(value), do: EmailAddress.normalize(value)
  defp page_size(nil), do: {:ok, 50}

  defp page_size(value) when is_binary(value) and byte_size(value) <= 3 do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100 -> {:ok, limit}
      _ -> {:error, :invalid_request}
    end
  end

  defp page_size(_), do: {:error, :invalid_request}

  defp fingerprint(email),
    do: :crypto.hash(:sha256, Jason.encode!(email)) |> Base.url_encode64(padding: false)

  defp encode_cursor(did, email),
    do: [1, fingerprint(email), did] |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp cursor(nil, _), do: {:ok, nil}

  defp cursor(value, email) when is_binary(value) and byte_size(value) <= 4096 do
    expected = fingerprint(email)

    with {:ok, bytes} <- Base.url_decode64(value, padding: false),
         {:ok, [1, ^expected, did]} <- Jason.decode(bytes),
         true <- Syntax.did?(did),
         do: {:ok, did},
         else: (_ -> {:error, :invalid_request})
  end

  defp cursor(_, _), do: {:error, :invalid_request}
end
