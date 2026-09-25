defmodule Atoll.Repo.Migrations.CreateBlocks do
  use Ecto.Migration

  def change do
    create table(:blocks, primary_key: false) do
      add :cid, :binary, primary_key: true, null: false
      add :data, :binary, null: false
    end

    create constraint(:blocks, :blocks_cid_length, check: "octet_length(cid) = 36")
  end
end
