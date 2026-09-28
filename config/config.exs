# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Ecto adapters are compiled into the repository; keep this set for every Mix command.
database =
  case System.get_env("ATOLL_DATABASE", "postgres") do
    value when value in ["postgres", "postgresql"] -> :postgres
    value when value in ["sqlite", "sqlite3"] -> :sqlite
    _ -> raise "ATOLL_DATABASE must be postgres or sqlite"
  end

config :atoll, :database, database

# Export is opt-in through OTEL_EXPORTER_OTLP_ENDPOINT at runtime.
config :atoll, :opentelemetry_enabled, false
config :atoll, :otlp_logs, false
config :opentelemetry, traces_exporter: :none, sampler: :always_off
config :opentelemetry_experimental, readers: []

if database == :sqlite do
  config :atoll, Atoll.Repo,
    priv: "priv/sqlite_repo",
    database: Path.expand("atoll_#{config_env()}.sqlite3"),
    # Serialize access at checkout as well as in SQLite: avoid competing writers
    # occupying driver threads while the current writer needs to finish.
    pool_size: 1,
    journal_mode: :wal,
    synchronous: :full,
    foreign_keys: :on,
    busy_timeout: 5_000,
    default_transaction_mode: :immediate
end

config :atoll,
  ecto_repos: [Atoll.Repo],
  record_write_rate_limit: 300,
  firehose_max_connections: 1024,
  firehose_max_connections_per_ip: 16,
  metrics_enabled: false,
  metrics_database_polling_enabled: true,
  passkeys_enabled: true,
  custom_domain_signup_self_service_enabled: false,
  custom_signup_reservation_limit: 1000,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :atoll, AtollWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AtollWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Atoll.PubSub,
  live_view: [signing_salt: "OPLzXhPP"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "client_assertion",
  "code_verifier",
  "request_uri",
  "state",
  "login_hint",
  "inviteCode",
  "note",
  "ref",
  "code",
  "codes",
  "cursor",
  "password",
  "identifier",
  "email",
  "token",
  "accessJwt",
  "refreshJwt",
  "authFactorToken",
  "totpCode"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
