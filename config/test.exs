import Config

config :relay, Relay.Repo,
  username: "relay_worker",
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

config :relay, Relay.QueueRepo,
  username: "relay_queue",
  password: "relay",
  hostname: "localhost",
  port: 5432,
  database: "relay_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2

config :relay, Oban, testing: :manual

config :relay, Relay.Platform.Outbox, dispatcher: false

config :relay, Relay.Platform.Leadership, enabled: false

config :logger, level: :warning

config :relay, Relay.NetworkGuard, enabled: true

config :relay, keys: RelayTest.Keys

config :relay, Relay.Keys, kek_label: "kek-test", fingerprint_label: "fingerprint-test"

config :phoenix, :plug_init_mode, :runtime
