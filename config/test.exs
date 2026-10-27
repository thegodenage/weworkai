import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :weworkai, Weworkai.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: "weworkai_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :weworkai, WeworkaiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3hsPpF2I6rOWTE/P+B+LjmF8V3IwHtRALCPVqNgMvdKXNNTK0tInBY9KOb0sjIxo",
  server: false

# In test we don't send emails
config :weworkai, Weworkai.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Ash runs some work in separate processes; keep it in the test process so the SQL sandbox applies.
config :ash,
  disable_async?: true,
  policies: [show_policy_breakdowns?: true],
  keyset_signing_secret: "QyX13/uCiWBvK/aiP3nXVSKDLQHWSlRLBN0TQ0HvPzw"

config :weworkai, :claude_bridge,
  url: "http://claude-bridge.test",
  token_path: "test/support/claude_bridge_token",
  req_options: [plug: {Req.Test, Weworkai.Connectors.ClaudeBridge}]

config :weworkai, start_scheduler: false
