# Invoked only by test_atoll_database_backup.py against its disposable databases.
import Ecto.Query
alias Atoll.{Repo, Repositories, KeyVault, Blobs, CID}
alias Atoll.Accounts.{Authenticator, Credentials, Sessions, TOTP, TOTPFactor, TOTPSecret}
alias Atoll.Repositories.{Events, Snapshot}

[phase, evidence_path] = System.argv()
database = System.fetch_env!("PGDATABASE")

unless phase in [
         "seed",
         "verify",
         "missing_s3",
         "remove_source_blob",
         "repair_source_blob",
         "corrupt_postgres_blob",
         "wrong_postgres_size",
         "remove_postgres_blob",
         "repair_postgres_blob"
       ] and
         Regex.match?(~r/\Aatoll_backup_test_[a-f0-9]{32}\z/, database),
       do: raise("This fixture requires a disposable backup-test database")

for app <- [:ecto_sql, :postgrex, :jose, :argon2_elixir],
    do: {:ok, _} = Application.ensure_all_started(app)

Application.put_env(:atoll, Atoll.Repo,
  database: database,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.fetch_env!("PGUSER"),
  password: System.get_env("PGPASSWORD"),
  pool: DBConnection.ConnectionPool,
  pool_size: 2,
  log: false
)

secret = System.fetch_env!("ATOLL_BACKUP_DRILL_SECRET") |> Base.decode16!(case: :mixed)
Application.put_env(:atoll, :key_encryption_key, secret)
Application.put_env(:atoll, :previous_key_encryption_keys, [])
Application.put_env(:atoll, :session_signing_key, secret)
Application.put_env(:atoll, :previous_session_signing_keys, [])
s3? = System.get_env("ATOLL_BACKUP_DRILL_S3") == "true"

storage =
  if s3? do
    endpoint = System.fetch_env!("ATOLL_MINIO_TEST_ENDPOINT")
    %URI{scheme: "http", host: "127.0.0.1", path: path} = URI.parse(endpoint)
    true = path in [nil, "", "/"]
    {:ok, _} = Application.ensure_all_started(:req)

    config = [
      endpoint: endpoint,
      bucket: String.replace_prefix(database, "atoll_backup_test_", "atoll-backup-"),
      region: "us-east-1",
      access_key_id: "atoll-test",
      secret_access_key: "atoll-minio-test-only"
    ]

    if phase in ["seed", "missing_s3"] do
      {:ok, %{status: 200}} =
        Req.put(endpoint <> "/" <> config[:bucket],
          aws_sigv4:
            [service: :s3] ++ Keyword.take(config, [:region, :access_key_id, :secret_access_key]),
          body: "",
          retry: false,
          redirect: false
        )
    end

    [backend: :s3, s3: config]
  else
    true =
      phase in [
        "seed",
        "verify",
        "corrupt_postgres_blob",
        "wrong_postgres_size",
        "remove_postgres_blob",
        "repair_postgres_blob"
      ]

    [backend: :postgres]
  end

Application.put_env(:atoll, :blob_storage, storage)
# Start only the repository. No web listeners, mail or background workers.
{:ok, supervisor} = Supervisor.start_link([Atoll.Repo], strategy: :one_for_one)

try do
  did = "did:plc:backupdrill"
  password = "disposable backup drill password"
  bytes = "backup drill blob\x00\xFF"
  path = "com.example.backup/record"
  pg_bytes = "database backup blob"
  pg_cid = CID.create(pg_bytes, :raw)

  cond do
    phase == "corrupt_postgres_blob" ->
      {1, _} =
        Repo.update_all(from(b in Atoll.Storage.Block, where: b.cid == ^pg_cid),
          set: [data: :binary.copy(<<0>>, byte_size(pg_bytes))]
        )

    phase == "wrong_postgres_size" ->
      {1, _} =
        Repo.update_all(from(b in Atoll.Blobs.Blob, where: b.did == ^did and b.cid == ^pg_cid),
          set: [size: byte_size(pg_bytes) + 1]
        )

    phase == "remove_postgres_blob" ->
      {1, _} = Repo.delete_all(from(b in Atoll.Storage.Block, where: b.cid == ^pg_cid))

    phase == "repair_postgres_blob" ->
      Repo.delete_all(from(b in Atoll.Storage.Block, where: b.cid == ^pg_cid))
      :ok = Atoll.Storage.put_block(pg_cid, pg_bytes)

      {1, _} =
        Repo.update_all(from(b in Atoll.Blobs.Blob, where: b.did == ^did and b.cid == ^pg_cid),
          set: [size: byte_size(pg_bytes)]
        )

    phase == "remove_source_blob" ->
      :ok = Atoll.Blobs.S3.delete(CID.create(bytes, :raw), storage[:s3])

    phase == "repair_source_blob" ->
      :ok = Atoll.Blobs.S3.put(CID.create(bytes, :raw), bytes, storage[:s3])

    phase == "missing_s3" ->
      # Database ownership alone must not serve an object from the old bucket.
      %{backend: :s3} = Repo.get_by!(Atoll.Blobs.Blob, did: did, cid: CID.create(bytes, :raw))
      {:error, :invalid_blob_storage} = Blobs.get_public(did, CID.create(bytes, :raw))
      {:error, :not_found} = Atoll.Storage.get_block(CID.create(bytes, :raw))

    phase == "seed" ->
      Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
      {:ok, _} = Repositories.create_managed(did)
      {:ok, _} = Credentials.create(did, password)
      {:ok, pair} = Sessions.create(did, password)
      {:ok, blob} = Blobs.stage(did, bytes, "application/octet-stream")
      {:ok, _} = Blobs.stage(did, pg_bytes, "text/plain", storage: [backend: :postgres])

      if s3? do
        {:ok, _} = Blobs.stage(did, "unpublished backup blob", "text/plain")

        :ok =
          Atoll.Blobs.S3.put(
            CID.create("untracked backup blob", :raw),
            "untracked backup blob",
            storage[:s3]
          )
      end

      {:ok, key} = KeyVault.fetch(did)

      {:ok, _} =
        Repositories.apply_writes(
          did,
          [{:put, path, %{"$type" => "com.example.backup", "blob" => blob}}],
          key
        )

      {:ok, _} =
        Atoll.Accounts.AdminInvites.create(%{"useCount" => 2, "forAccount" => did}, "operator")

      first = Repo.one!(from e in Atoll.Repositories.Event, order_by: e.seq, limit: 1)

      Repo.update_all(from(e in Atoll.Repositories.Event, where: e.seq == ^first.seq),
        set: [time: DateTime.add(DateTime.utc_now(), -7200, :second)]
      )

      {:ok, %{deleted: 1}} = Atoll.Repositories.EventRetention.prune(1, 3600)
      {:ok, archive} = Repositories.export(did)

      # Exercise real enrollment and consumption before the snapshot. The expired
      # attempt window is intentional fixture state; restoration must retain the
      # used step and recovery hashes while allowing the normal window rollover.
      {:ok, enrollment} = Authenticator.begin(pair.access_jwt, password)
      totp_secret = Base.decode32!(enrollment.secret, padding: false)

      %{rows: [[enrollment_time]]} =
        Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      {:ok, enrollment_code} = TOTP.code(totp_secret, enrollment_time)

      {:ok, %{recovery_codes: [used_recovery, unused_recovery | _]}} =
        Authenticator.confirm(pair.access_jwt, enrollment_code)

      {:ok, _} = Sessions.create(did, password, totp_code: used_recovery)
      factor = Repo.get!(TOTPFactor, did)
      true = length(factor.recovery_hashes) == 9
      factor |> Ecto.Changeset.change(window_started_at: 0) |> Repo.update!(log: false)

      evidence = %{
        totp: %{
          secret: Base.encode64(totp_secret),
          enrollment_time: enrollment_time,
          enrollment_code: enrollment_code,
          step: factor.last_used_step,
          version: factor.version,
          envelope: Base.encode64(factor.envelope),
          hashes: Enum.map(factor.recovery_hashes, &Base.encode64/1),
          attempts: factor.attempts,
          used_recovery: used_recovery,
          unused_recovery: unused_recovery
        },
        public: Base.encode64(key.public),
        car: Base.encode64(archive),
        access: pair.access_jwt,
        refresh: pair.refresh_jwt,
        sequence: Events.latest_seq(),
        floor: Atoll.Repositories.EventRetention.bounds().floor,
        quota: Atoll.Repositories.Quota.usage(did),
        migrations: Repo.query!("SELECT count(*) FROM schema_migrations").rows
      }

      File.write!(evidence_path, Jason.encode!(evidence), [:exclusive])
      File.chmod!(evidence_path, 0o600)

    phase == "verify" ->
      evidence = evidence_path |> File.read!() |> Jason.decode!()
      {:ok, %{did: ^did}} = Credentials.verify(did, password)
      {:ok, %{did: ^did}} = Sessions.authenticate(evidence["access"])
      {:ok, _} = Sessions.refresh(evidence["refresh"])
      totp = evidence["totp"]
      factor = Repo.get!(TOTPFactor, did)
      true = factor.version == totp["version"]
      true = factor.last_used_step == totp["step"]
      true = factor.attempts == totp["attempts"] and factor.window_started_at == 0
      true = Base.encode64(factor.envelope) == totp["envelope"]
      true = Enum.map(factor.recovery_hashes, &Base.encode64/1) == totp["hashes"]
      {:ok, %{state: :enabled, recovery_remaining: 9}} = Authenticator.status(evidence["access"])
      {:error, :totp_required} = Sessions.create(did, password)
      session_count = Repo.aggregate(Atoll.Accounts.Session, :count)
      Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
      {:error, :key_decryption_failed} = KeyVault.fetch(did)
      {:error, :key_decryption_failed} = TOTPSecret.open(did, factor.envelope)
      {:error, :key_decryption_failed} = Sessions.create(did, password, totp_code: "123456")
      true = Repo.aggregate(Atoll.Accounts.Session, :count) == session_count
      Application.put_env(:atoll, :key_encryption_key, secret)
      {:ok, restored_secret} = TOTPSecret.open(did, factor.envelope)
      true = Base.encode64(restored_secret) == totp["secret"]
      # Verify replay at the original time too, so a slow drill cannot pass solely
      # because the pre-backup code has aged out of the acceptance window.
      {:error, :invalid_totp} =
        TOTP.verify(
          restored_secret,
          totp["enrollment_code"],
          totp["enrollment_time"],
          factor.last_used_step
        )

      {:error, :invalid_totp} = Sessions.create(did, password, totp_code: totp["used_recovery"])

      %{rows: [[now]]} =
        Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

      fresh_code =
        Enum.find_value([now, now + 30], fn time ->
          {:ok, code} = TOTP.code(restored_secret, time)

          if match?({:ok, _}, TOTP.verify(restored_secret, code, now, factor.last_used_step)),
            do: code
        end)

      true = is_binary(fresh_code)
      {:ok, fresh_pair} = Sessions.create(did, password, totp_code: fresh_code)
      {:ok, %{did: ^did}} = Sessions.authenticate(fresh_pair.access_jwt)
      {:error, :invalid_totp} = Sessions.create(did, password, totp_code: fresh_code)
      {:ok, recovery_pair} = Sessions.create(did, password, totp_code: totp["unused_recovery"])
      {:ok, %{did: ^did}} = Sessions.authenticate(recovery_pair.access_jwt)
      {:error, :invalid_totp} = Sessions.create(did, password, totp_code: totp["unused_recovery"])
      {:ok, %{state: :enabled, recovery_remaining: 8}} = Authenticator.status(evidence["access"])
      {:ok, key} = KeyVault.fetch(did)
      true = Base.encode64(key.public) == evidence["public"]
      {:ok, archive} = Repositories.export(did)
      true = Base.encode64(archive) == evidence["car"]
      {:ok, snapshot} = Snapshot.decode(archive, did, key.curve, key.public)
      true = Map.has_key?(snapshot.records, path)
      {:ok, %{bytes: ^bytes}} = Blobs.get_public(did, CID.create(bytes, :raw))
      {:ok, %{bytes: ^pg_bytes}} = Blobs.get_staged(did, pg_cid)
      {:error, :blob_not_found} = Blobs.get_public(did, pg_cid)
      %{backend: :postgres} = Repo.get_by!(Atoll.Blobs.Blob, did: did, cid: pg_cid)

      if s3? do
        cid = CID.create("unpublished backup blob", :raw)
        {:ok, %{bytes: "unpublished backup blob"}} = Blobs.get_staged(did, cid)
        {:error, :blob_not_found} = Blobs.get_public(did, cid)

        {:ok, "untracked backup blob"} =
          Atoll.Blobs.S3.get(CID.create("untracked backup blob", :raw), storage[:s3])

        {:error, :not_found} = Atoll.Storage.get_block(CID.create(bytes, :raw))
        %{backend: :s3} = Repo.get_by!(Atoll.Blobs.Blob, did: did, cid: CID.create(bytes, :raw))
      end

      true = Events.latest_seq() == evidence["sequence"]

      true =
        Jason.decode!(Jason.encode!(Atoll.Repositories.Quota.usage(did))) == evidence["quota"]

      true = Repo.query!("SELECT count(*) FROM schema_migrations").rows == evidence["migrations"]
      true = Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 2
      floor = Atoll.Repositories.EventRetention.bounds().floor
      true = floor == evidence["floor"] and floor > 0
      {:error, :outdated_cursor} = Events.list_after(floor - 1)
      {:ok, events} = Events.list_after(floor)
      for event <- events, do: {:ok, _} = Atoll.Repositories.EventEncoder.encode(event)
      # Exercise restored triggers, indexes, sequences and retained signing custody.
      record = %{"$type" => "com.example.backup", "restored" => true}

      record =
        if s3? do
          {:ok, %{blob: blob}} =
            Blobs.get_staged(did, CID.create("unpublished backup blob", :raw))

          Map.put(record, "blob", blob)
        else
          record
        end

      {:ok, _} =
        Repositories.apply_writes(
          did,
          [{:put, "com.example.backup/after", record}],
          key
        )

      true = Events.latest_seq() > evidence["sequence"]

      if s3? do
        {:ok, %{bytes: "unpublished backup blob"}} =
          Blobs.get_public(did, CID.create("unpublished backup blob", :raw))
      end
  end

  IO.puts("Atoll restore fixture #{phase} passed")
rescue
  error ->
    IO.puts(:stderr, "Atoll restore fixture #{phase} failed (#{inspect(error.__struct__)})")
    System.halt(1)
after
  Supervisor.stop(supervisor)
end
