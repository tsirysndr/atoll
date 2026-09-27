# SQLite's sandbox permits a single writer. Serialize test cases while retaining
# explicit multi-connection concurrency tests.
if Atoll.Database.adapter() == :sqlite, do: ExUnit.configure(max_cases: 1)

ExUnit.start(
  exclude:
    [:minio, :redis, :browser, :interop] ++
      if(Atoll.Database.adapter() == :sqlite, do: [:postgres], else: [])
)

Ecto.Adapters.SQL.Sandbox.mode(Atoll.Repo, :manual)
