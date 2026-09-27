ExUnit.start(exclude: [:minio, :redis, :browser, :interop])
Ecto.Adapters.SQL.Sandbox.mode(Atoll.Repo, :manual)
