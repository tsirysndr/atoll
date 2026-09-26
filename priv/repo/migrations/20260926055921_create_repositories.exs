defmodule Atoll.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories, primary_key: false) do
      add :did, :text, primary_key: true
      add :head, references(:blocks, column: :cid, type: :binary), null: false
      add :rev, :string, size: 13, null: false
      add :public_key, :binary, null: false
      add :curve, :string, null: false
    end

    create constraint(:repositories, :repository_curve, check: "curve IN ('p256', 'k256')")

    create constraint(:repositories, :repository_public_key,
             check: "octet_length(public_key) = 33"
           )

    create table(:repository_records, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :path, :text, primary_key: true
      add :cid, references(:blocks, column: :cid, type: :binary), null: false
    end
  end
end
