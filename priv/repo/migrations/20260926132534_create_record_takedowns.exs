defmodule Atoll.Repo.Migrations.CreateRecordTakedowns do
  use Ecto.Migration

  def change do
    create table(:record_takedowns, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :path, :text, primary_key: true
      add :cid, :binary, null: false
      add :ref, :text
    end

    create constraint(:record_takedowns, :record_takedown_ref_size,
             check: "ref IS NULL OR octet_length(ref) <= 2000"
           )
  end
end
