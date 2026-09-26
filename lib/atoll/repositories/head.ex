defmodule Atoll.Repositories.Head do
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "repositories" do
    field :head, :binary
    field :rev, :string
    field :public_key, :binary
    field :curve, Ecto.Enum, values: [:p256, :k256]

    field :takedown_ref, :string, redact: true
    field :pre_takedown_status, Ecto.Enum, values: [:active, :deactivated, :suspended]

    field :status, Ecto.Enum,
      values: [:active, :deactivated, :takendown, :suspended],
      default: :active
  end
end
