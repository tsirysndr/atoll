# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tailwind,
  version: "4.3.0",
  atoll: [
    args: ~w(--input=assets/css/account.css --output=priv/static/assets/account.css),
    cd: Path.expand("..", __DIR__)
  ]

config :atoll,
  ecto_repos: [Atoll.Repo],
  record_write_rate_limit: 300,
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
