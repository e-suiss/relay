import Config

config :relay, Relay.Repo,
  username: "relay",
  password: "relay",
  hostname: "localhost",
  port: 5432,
  database: "relay_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :relay, RelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-000000000000000000000000000000000000000000000",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
