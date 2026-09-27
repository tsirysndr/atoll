defmodule Atoll.ReadRepo do
  @moduledoc "Optional read-only pool. Never included in ecto_repos or migrated."
  use Ecto.Repo,
    otp_app: :atoll,
    adapter: Ecto.Adapters.Postgres,
    read_only: true

  def children do
    if Application.get_env(:atoll, :read_repo_enabled, false), do: [__MODULE__], else: []
  end

  @impl true
  def init(_type, config) do
    parameters =
      Keyword.put(Keyword.get(config, :parameters, []), :default_transaction_read_only, "on")

    {:ok,
     config
     |> Keyword.put(:parameters, parameters)
     |> Keyword.put(:telemetry_prefix, [:atoll, :repo])}
  end
end
