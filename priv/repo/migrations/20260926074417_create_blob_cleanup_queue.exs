defmodule Atoll.Repo.Migrations.CreateBlobCleanupQueue do
  use Ecto.Migration

  def change do
    create table(:blob_cleanup_jobs, primary_key: false) do
      add :cid, :binary, primary_key: true
      add :backend, :text, primary_key: true
      add :queued_at, :utc_datetime_usec, null: false
    end

    create index(:blob_cleanup_jobs, [:queued_at])

    create constraint(:blob_cleanup_jobs, :cleanup_backend,
             check: "backend IN ('postgres', 's3')"
           )

    create constraint(:blob_cleanup_jobs, :cleanup_raw_cid,
             check:
               "octet_length(cid) = 36 AND substring(cid from 1 for 4) = decode('01551220', 'hex')"
           )
  end
end
