import Config

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
#     PHX_SERVER=true bin/titan_flow start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :titan_flow, TitanFlowWeb.Endpoint, server: true
end

config :titan_flow, TitanFlowWeb.Endpoint,
  url: [host: "dashboard.getfastloans.in", port: 443, scheme: "https"],
  http: [port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: ["//dashboard.getfastloans.in", "//localhost"]

# PostgreSQL Database Configuration (all environments)
# Using Supavisor connection pooler (port 6543) - REQUIRED for production
# Direct connection (port 5432/5433) will cause "too_many_connections" errors
db_port = String.to_integer(System.get_env("DATABASE_PORT") || "6543")  # FORCED to Supavisor

# Warn if using direct PostgreSQL port in production
if config_env() == :prod and db_port in [5432, 5433] do
  IO.puts("[WARNING] Database port #{db_port} detected - this bypasses Supavisor!")
  IO.puts("[WARNING] For production, use port 6543 (Supavisor Transaction Mode)")
end

# Socket options - use inet6 if available, otherwise inet
socket_opts = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: [:inet]

config :titan_flow, TitanFlow.Repo,
  # Supavisor requires tenant format: postgres.{tenant_id} where tenant_id = "postgres"
  username: System.get_env("DATABASE_USERNAME") || "postgres.postgres",
  password: System.get_env("DATABASE_PASSWORD") || "dWupoUeRBRJcr_7NGOIw_RLleVpd8c5AySgWV10Zp9Q",
  hostname: System.get_env("DATABASE_HOST") || "85.17.142.45",
  port: db_port,
  database: System.get_env("DATABASE_NAME") || "titan_flow",  # Your actual database name
  # Supavisor Transaction Mode settings (critical for connection pooler)
  prepare: :unnamed,  # Required for Supavisor transaction mode - don't use named prepared statements
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),  # Low pool size - Supavisor scales externally
  socket_options: socket_opts

# Redis Configuration (Redix)
config :titan_flow, :redix,
  host: "85.17.142.45",
  port: 6379,
  password: "J4Rlz_-uxl8FTFdoKn9sYksG628c8EFZUVJNuoHFQRU"

# ClickHouse removed - using Postgres for all logging

# Hammer Rate Limiter with Redis Backend
config :hammer,
  backend: {Hammer.Backend.Redis, [
    expiry_ms: 60_000 * 60 * 2, # Keep buckets for 2 hours
    redix_config: [
      host: "85.17.142.45",
      port: 6379,
      password: "J4Rlz_-uxl8FTFdoKn9sYksG628c8EFZUVJNuoHFQRU"
    ]
  ]}

# OpenAI Configuration
config :titan_flow, :openai_api_key, System.get_env("OPENAI_API_KEY")

# Webhook Verification Token
config :titan_flow, :webhook_verify_token, System.get_env("WEBHOOK_VERIFY_TOKEN", "titanflow_webhook_secret")

# Admin PIN for dashboard access
config :titan_flow, :admin_pin, System.get_env("ADMIN_PIN", "766100")

if config_env() == :prod do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # config :titan_flow, TitanFlow.Repo,
  #   socket_options: maybe_ipv6

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

  host = System.get_env("PHX_HOST") || "example.com"

  config :titan_flow, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :titan_flow, TitanFlowWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :titan_flow, TitanFlowWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :titan_flow, TitanFlowWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
