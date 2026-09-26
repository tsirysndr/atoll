defmodule Atoll.Repo.Migrations.CreateRepositoryBlobs do
  use Ecto.Migration

  def change do
    create table(:repository_blobs, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :binary, primary_key: true
      add :backend, :text, null: false
      add :mime_type, :text, null: false
      add :size, :bigint, null: false
      add :staged_at, :utc_datetime_usec, null: false
    end

    create constraint(:repository_blobs, :blob_size, check: "size >= 0 AND size <= 5242880")
    create constraint(:repository_blobs, :blob_backend, check: "backend IN ('postgres', 's3')")

    create constraint(:repository_blobs, :blob_raw_cid,
             check:
               "octet_length(cid) = 36 AND substring(cid from 1 for 4) = decode('01551220', 'hex')"
           )

    create constraint(:repository_blobs, :blob_mime_type,
             check: "length(mime_type) BETWEEN 3 AND 255"
           )

    create index(:repository_blobs, [:staged_at])
  end
end
