ExUnit.start(exclude: [:minio, :redis])
Ecto.Adapters.SQL.Sandbox.mode(Atoll.Repo, :manual)
