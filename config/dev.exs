import Config

config :relay, Relay.Repo,
  username: "relay_worker",
  password: "relay",
  hostname: "localhost",
  port: 5432,
  database: "relay_dev",
  pool_size: 10

config :relay, Relay.QueueRepo,
  username: "relay_queue",
  password: "relay",
  hostname: "localhost",
  port: 5432,
  database: "relay_dev",
  pool_size: 2

config :relay, RelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: false,
  secret_key_base: "dev-only-secret-key-base-0000000000000000000000000000000000000000000000",
  watchers: []

config :relay, RelayWeb.Metrics, server: true, ip: {127, 0, 0, 1}, port: 9568

config :relay, Relay.NetworkGuard, enabled: true

config :relay, Relay.Access,
  issuer: "https://access.localhost",
  http: [plug: {RelayDev.Access, []}]

config :relay, Relay.Audit,
  publishers: [
    {"worm_store", Relay.Audit.Checkpointer.Publisher.S3,
     [
       endpoint: "http://localhost:9000",
       bucket: "relay-audit",
       region: "us-east-1",
       access_key_id: "relay",
       secret_access_key: "relay-dev-secret",
       prefix: ""
     ]}
  ]

config :phoenix, :plug_init_mode, :runtime

config :relay, Relay.Keys.Port,
  module:
    System.get_env("PKCS11_MODULE") ||
      Enum.find(
        [
          "/opt/homebrew/lib/softhsm/libsofthsm2.so",
          "/usr/local/lib/softhsm/libsofthsm2.so",
          "/usr/lib/softhsm/libsofthsm2.so",
          "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so"
        ],
        "/usr/lib/softhsm/libsofthsm2.so",
        &File.exists?/1
      ),
  token: "relay-dev",
  pin_file: Path.expand("../deploy/softhsm/pin", __DIR__)

config :relay, Relay.Keys,
  kek_label: "kek-dev",
  fingerprint_label: "fingerprint-dev",
  cursor_label: "cursor-dev"
