ExUnit.start(exclude: [:minio, :redis, :browser])
Ecto.Adapters.SQL.Sandbox.mode(Atoll.Repo, :manual)
