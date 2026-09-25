defmodule Atoll.Repo do
  use Ecto.Repo,
    otp_app: :atoll,
    adapter: Ecto.Adapters.Postgres
end
