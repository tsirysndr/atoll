defmodule Atoll.Repositories.EncryptedKey do
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "repository_keys" do
    field :envelope, :binary, redact: true
  end
end
