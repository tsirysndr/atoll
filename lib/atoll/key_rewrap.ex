defmodule Atoll.KeyRewrap do
  @moduledoc "Bounded operator rewrapping of repository and retained PLC private-key envelopes."
  import Ecto.Query
  alias Atoll.{KeyVault, MasterKeys, Repo, Syntax}
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.PLC.Registrations

  def batch(limit \\ 100, after_did \\ nil)

  def batch(limit, after_did) when is_integer(limit) and limit in 1..100 do
    if is_nil(after_did) or Syntax.did?(after_did) do
      with {:ok, master} <- MasterKeys.active() do
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '1s'")
          Repo.query!("SET LOCAL statement_timeout = '5s'")
          Events.lock!()
          query = from h in Head, order_by: h.did, limit: ^(limit + 1)
          query = if after_did, do: from(h in query, where: h.did > ^after_did), else: query
          heads = Repo.all(query)
          page = Enum.take(heads, limit)

          counts =
            Enum.reduce(
              page,
              %{repositories: 0, plc: 0, unchanged: 0, scanned: length(page)},
              fn h, counts ->
                head = Repo.one!(from r in Head, where: r.did == ^h.did, lock: "FOR UPDATE")
                counts = count(counts, :repositories, KeyVault.rewrap!(head, master))
                count(counts, :plc, Registrations.rewrap!(head.did, master))
              end
            )

          if length(heads) > limit,
            do: Map.put(counts, :cursor, List.last(page).did),
            else: counts
        end)
      end
    else
      {:error, :invalid_rewrap_options}
    end
  rescue
    _ in Postgrex.Error -> {:error, :rewrap_failed}
  end

  def batch(_, _), do: {:error, :invalid_rewrap_options}
  defp count(counts, _, :absent), do: counts
  defp count(counts, _, :unchanged), do: Map.update!(counts, :unchanged, &(&1 + 1))
  defp count(counts, kind, :rotated), do: Map.update!(counts, kind, &(&1 + 1))
end
