defmodule Atoll.Repo.Migrations.CreateRequestRateBuckets do
  use Ecto.Migration

  def change do
    create table(:request_rate_buckets, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :count, :integer, null: false
      add :expires_at, :bigint, null: false
    end

    create index(:request_rate_buckets, [:expires_at])

    create constraint(:request_rate_buckets, :rate_bucket_digest_length,
             check: "octet_length(digest) = 32"
           )

    create constraint(:request_rate_buckets, :rate_bucket_count, check: "count > 0")
    create constraint(:request_rate_buckets, :rate_bucket_expiration, check: "expires_at > 0")
  end
end
