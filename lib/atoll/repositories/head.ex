defmodule Atoll.Repositories.Head do
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "repositories" do
    field :head, :binary
    field :rev, :string
    field :public_key, :binary
    field :curve, Ecto.Enum, values: [:p256, :k256]

    field :status, Ecto.Enum,
      values: [:active, :deactivated, :takendown, :suspended],
      default: :active
  end
end
