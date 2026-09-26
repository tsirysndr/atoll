defmodule Atoll.Repositories.Event do
  use Ecto.Schema

  @primary_key {:seq, :id, autogenerate: true}
  schema "repository_events" do
    field :did, :string
    field :kind, Ecto.Enum, values: [:commit, :sync, :account, :identity]
    field :payload, :binary
    field :time, :utc_datetime_usec
  end
end
