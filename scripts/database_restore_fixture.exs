# Invoked only by test_atoll_database_backup.py against its disposable databases.
import Ecto.Query
alias Atoll.{Repo, Repositories, KeyVault, Blobs, CID}
alias Atoll.Accounts.{Credentials, Sessions}
alias Atoll.Repositories.{Events, Snapshot}

[phase, evidence_path] = System.argv()
database = System.fetch_env!("PGDATABASE")

unless phase in ["seed", "verify"] and
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
Application.put_env(:atoll, :blob_storage, backend: :postgres)
# Start only the repository. No web listeners, mail or background workers.
{:ok, supervisor} = Supervisor.start_link([Atoll.Repo], strategy: :one_for_one)

try do
  did = "did:plc:backupdrill"
  password = "disposable backup drill password"
  bytes = "backup drill blob\x00\xFF"
  path = "com.example.backup/record"

  if phase == "seed" do
    Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
    {:ok, _} = Repositories.create_managed(did)
    {:ok, _} = Credentials.create(did, password)
    {:ok, pair} = Sessions.create(did, password)
    {:ok, blob} = Blobs.stage(did, bytes, "application/octet-stream")
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

    evidence = %{
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
  else
    evidence = evidence_path |> File.read!() |> Jason.decode!()
    {:ok, %{did: ^did}} = Credentials.verify(did, password)
    {:ok, %{did: ^did}} = Sessions.authenticate(evidence["access"])
    {:ok, _} = Sessions.refresh(evidence["refresh"])
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    {:error, :key_decryption_failed} = KeyVault.fetch(did)
    Application.put_env(:atoll, :key_encryption_key, secret)
    {:ok, key} = KeyVault.fetch(did)
    true = Base.encode64(key.public) == evidence["public"]
    {:ok, archive} = Repositories.export(did)
    true = Base.encode64(archive) == evidence["car"]
    {:ok, snapshot} = Snapshot.decode(archive, did, key.curve, key.public)
    true = Map.has_key?(snapshot.records, path)
    {:ok, %{bytes: ^bytes}} = Blobs.get_public(did, CID.create(bytes, :raw))
    true = Events.latest_seq() == evidence["sequence"]
    true = Jason.decode!(Jason.encode!(Atoll.Repositories.Quota.usage(did))) == evidence["quota"]
    true = Repo.query!("SELECT count(*) FROM schema_migrations").rows == evidence["migrations"]
    true = Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 2
    floor = Atoll.Repositories.EventRetention.bounds().floor
    true = floor == evidence["floor"] and floor > 0
    {:error, :outdated_cursor} = Events.list_after(floor - 1)
    {:ok, events} = Events.list_after(floor)
    for event <- events, do: {:ok, _} = Atoll.Repositories.EventEncoder.encode(event)
    # Exercise restored triggers, indexes, sequences and retained signing custody.
    {:ok, _} =
      Repositories.apply_writes(
        did,
        [
          {:put, "com.example.backup/after",
           %{"$type" => "com.example.backup", "restored" => true}}
        ],
        key
      )

    true = Events.latest_seq() > evidence["sequence"]
  end

  IO.puts("Atoll restore fixture #{phase} passed")
rescue
  error ->
    IO.puts(:stderr, "Atoll restore fixture #{phase} failed (#{inspect(error.__struct__)})")
    System.halt(1)
after
  Supervisor.stop(supervisor)
end
