defmodule Atoll.Repo.Migrations.CreateBlobTakedowns do
  use Ecto.Migration

  def change do
    create table(:blob_takedowns, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :binary, primary_key: true
      add :ref, :text
    end

    create constraint(:blob_takedowns, :blob_takedown_ref_size,
             check: "ref IS NULL OR octet_length(ref) <= 2000"
           )
  end
end
