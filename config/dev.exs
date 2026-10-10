import Config

config :relay, Relay.Repo,
  username: "relay",
  password: "relay",
  hostname: "localhost",
  port: 5432,
  database: "relay_dev",
  pool_size: 10

config :relay, RelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: false,
  secret_key_base: "dev-only-secret-key-base-0000000000000000000000000000000000000000000000",
  watchers: []

config :phoenix, :plug_init_mode, :runtime
