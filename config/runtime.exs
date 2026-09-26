import Config

config :atoll,
       :import_concurrency,
       Atoll.CAR.StageLease.limit_from_env!(System.get_env("ATOLL_IMPORT_CONCURRENCY"))

config :atoll,
       :network_lexicons_enabled,
       Atoll.Lexicon.WriteValidation.enabled_from_env!(System.get_env("ATOLL_NETWORK_LEXICONS"))

if directory = System.get_env("ATOLL_LEXICON_DIRECTORY") do
  config :atoll, :record_lexicons, Atoll.Lexicon.Loader.load!(directory)
end

config :atoll,
       :invite_allocation,
       Atoll.Accounts.InviteAllocation.config_from_env!(System.get_env())

config :atoll,
       :admin_password,
       Atoll.Accounts.AdminAuth.password_from_env!(System.get_env("ATOLL_ADMIN_PASSWORD"))

case System.get_env("ATOLL_INVITE_CODE_REQUIRED", "false") do
  "true" -> config :atoll, :invite_code_required, true
  "false" -> config :atoll, :invite_code_required, false
  _ -> raise "ATOLL_INVITE_CODE_REQUIRED must be true or false"
end

config :atoll,
       :localhost_dids_enabled,
       Atoll.Identity.Localhost.parse_enabled!(
         System.get_env("ATOLL_LOCALHOST_DIDS_ENABLED"),
         config_env()
       )

config :atoll,
       :rate_limit_backend,
       Atoll.Accounts.SessionLimiter.backend_from_env!(System.get_env("ATOLL_RATE_LIMIT_BACKEND"))

config :atoll,
       :redis,
       Atoll.Redis.config!(
         System.get_env(),
         Atoll.Accounts.SessionLimiter.backend_from_env!(
           System.get_env("ATOLL_RATE_LIMIT_BACKEND")
         )
       )

config :atoll,
       :trusted_proxies,
       AtollWeb.ClientIP.parse_trusted_proxies!(System.get_env("ATOLL_TRUSTED_PROXY_CIDRS"))

config :atoll,
       :xrpc_rate_limit,
       AtollWeb.XRPCRequestPlug.rate_limit_from_env!(System.get_env("ATOLL_XRPC_RATE_LIMIT"))

case Integer.parse(System.get_env("ATOLL_HANDLE_CACHE_TTL_SECONDS", "60")) do
  {ttl, ""} when ttl in 0..300 -> config :atoll, :handle_cache_ttl_seconds, ttl
  _ -> raise "ATOLL_HANDLE_CACHE_TTL_SECONDS must be an integer from 0 to 300"
end

case Integer.parse(System.get_env("ATOLL_DID_CACHE_TTL_SECONDS", "60")) do
  {ttl, ""} when ttl in 0..300 -> config :atoll, :did_cache_ttl_seconds, ttl
  _ -> raise "ATOLL_DID_CACHE_TTL_SECONDS must be an integer from 0 to 300"
end

case System.get_env("ATOLL_CUSTOM_DOMAIN_SIGNUP_ENABLED", "false") do
  "true" -> config :atoll, :custom_domain_signup_enabled, true
  "false" -> config :atoll, :custom_domain_signup_enabled, false
  _ -> raise "ATOLL_CUSTOM_DOMAIN_SIGNUP_ENABLED must be true or false"
end

case System.get_env("ATOLL_SIGNUP_ENABLED", "false") do
  "true" -> config :atoll, :signup_enabled, true
  "false" -> config :atoll, :signup_enabled, false
  _ -> raise "ATOLL_SIGNUP_ENABLED must be true or false"
end

config :atoll,
       :plc_resolution_mode,
       Atoll.Identity.Resolver.plc_mode_from_env!(System.get_env("ATOLL_PLC_RESOLUTION_MODE"))

config :atoll,
       :plc_directory_url,
       Atoll.Identity.PLC.Client.directory_from_env!(System.get_env("ATOLL_PLC_DIRECTORY_URL"))

config :atoll,
       :previous_key_encryption_keys,
       Atoll.MasterKeys.previous_from_env!(System.get_env("ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS"))

config :atoll, :relay_urls, Atoll.Relays.from_env!(System.get_env("ATOLL_RELAY_URLS"))
relay_schedule = Atoll.Relays.schedule_from_env!(System.get_env(), config_env() == :test)
config :atoll, :relay_crawl_enabled, relay_schedule.enabled
config :atoll, :relay_crawl_interval_seconds, relay_schedule.interval_seconds

retention =
  Atoll.Repositories.EventRetention.config_from_env!(System.get_env(), config_env() == :test)

config :atoll, :event_retention_enabled, retention.enabled
config :atoll, :event_retention_seconds, retention.seconds

config :atoll,
       :email_worker,
       Atoll.Email.Config.parse!(System.get_env(), Application.get_env(:atoll, :email_worker, []))

server = Atoll.ServerConfig.parse!(System.get_env(), config_env() == :prod)
config :atoll, :pds, server.pds

if key = Atoll.Identity.Server.key_from_env!(System.get_env("ATOLL_PDS_SIGNING_KEY")) do
  config :atoll, :server_identity_key, key
end

case Integer.parse(System.get_env("ATOLL_SESSION_MAX_COUNT", "100")) do
  {limit, ""} when limit in 0..1000 -> config :atoll, :session_max_count, limit
  _ -> raise "ATOLL_SESSION_MAX_COUNT must be an integer from 0 to 1000"
end

config :atoll,
       :previous_session_signing_keys,
       Atoll.Accounts.Tokens.previous_from_env!(
         System.get_env("ATOLL_PREVIOUS_SESSION_SIGNING_KEYS")
       )

if encoded = System.get_env("ATOLL_SESSION_SIGNING_KEY") do
  case Base.decode64(encoded) do
    {:ok, <<_::binary-size(32)>> = key} -> config :atoll, :session_signing_key, key
    _ -> raise "ATOLL_SESSION_SIGNING_KEY must be a base64-encoded 32-byte key"
  end
end

nonnegative_integer = fn name, default ->
  value = System.get_env(name, default)

  case Integer.parse(value) do
    {number, ""} when number >= 0 -> number
    _ -> raise "#{name} must be a nonnegative integer"
  end
end

config :atoll, :repository_quota,
  max_bytes: nonnegative_integer.("ATOLL_REPO_MAX_ACCOUNT_BYTES", "1073741824"),
  max_count: nonnegative_integer.("ATOLL_REPO_MAX_ACCOUNT_BLOCKS", "1000000")

config :atoll, :blob_quota,
  max_bytes: nonnegative_integer.("ATOLL_BLOB_MAX_ACCOUNT_BYTES", "1073741824"),
  max_count: nonnegative_integer.("ATOLL_BLOB_MAX_ACCOUNT_COUNT", "10000")

signup_cleanup = Atoll.Accounts.SignupCleanup.config_from_env!(System.get_env())

config :atoll,
       :signup_cleanup,
       Keyword.put(signup_cleanup, :enabled, signup_cleanup[:enabled] and config_env() != :test)

case System.get_env("ATOLL_ACCOUNT_CLEANUP_ENABLED", "false") do
  "true" -> config :atoll, :account_cleanup_enabled, config_env() != :test
  "false" -> config :atoll, :account_cleanup_enabled, false
  _ -> raise "ATOLL_ACCOUNT_CLEANUP_ENABLED must be true or false"
end

case System.get_env("ATOLL_BLOB_CLEANUP_ENABLED", "false") do
  "true" -> config :atoll, :blob_cleanup_enabled, config_env() != :test
  "false" -> config :atoll, :blob_cleanup_enabled, false
  _ -> raise "ATOLL_BLOB_CLEANUP_ENABLED must be true or false"
end

case System.get_env("ATOLL_BLOB_STORAGE", "postgres") do
  "postgres" ->
    config :atoll, :blob_storage, backend: :postgres

  "s3" ->
    required = fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _ -> raise "#{name} is required for S3 blob storage"
      end
    end

    config :atoll, :blob_storage,
      backend: :s3,
      s3: [
        endpoint: required.("ATOLL_S3_ENDPOINT"),
        bucket: required.("ATOLL_S3_BUCKET"),
        region: System.get_env("ATOLL_S3_REGION", "us-east-1"),
        access_key_id: required.("ATOLL_S3_ACCESS_KEY_ID"),
        secret_access_key: required.("ATOLL_S3_SECRET_ACCESS_KEY"),
        session_token: System.get_env("ATOLL_S3_SESSION_TOKEN")
      ]

  _ ->
    raise "ATOLL_BLOB_STORAGE must be postgres or s3"
end

case System.get_env("ATOLL_IDENTITY_REFRESH_ENABLED", "false") do
  "true" -> config :atoll, :identity_refresh_enabled, true
  "false" -> config :atoll, :identity_refresh_enabled, false
  _ -> raise "ATOLL_IDENTITY_REFRESH_ENABLED must be true or false"
end

if encoded = System.get_env("ATOLL_KEY_ENCRYPTION_KEY") do
  case Base.decode64(encoded) do
    {:ok, <<_::binary-size(32)>> = key} -> config :atoll, :key_encryption_key, key
    _ -> raise "ATOLL_KEY_ENCRYPTION_KEY must be a base64-encoded 32-byte key"
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/atoll start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :atoll, AtollWeb.Endpoint, server: true
end

config :atoll, AtollWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :atoll, Atoll.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = server.host

  config :atoll, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :atoll, AtollWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :atoll, AtollWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :atoll, AtollWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
