import Config

config :relay,
  ecto_repos: [Relay.Repo],
  roles: [:api, :worker, :socket],
  clock: Relay.Clock.System,
  random: Relay.Random.Strong,
  keys: Relay.Keys.Port

config :relay, Relay.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :relay, Relay.Platform.Valkey,
  adapter: Relay.Platform.Valkey.Redix,
  url: "redis://localhost:6379"

config :relay, Relay.Platform.Signal, poll_interval_ms: 1_000

config :relay, Oban,
  repo: Relay.Repo,
  prefix: "relay_queue",
  notifier: Relay.Platform.Queue.Notifier,
  peer: Oban.Peers.Database,
  queues: [],
  plugins: []

config :relay, RelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: RelayWeb.ErrorJSON], layout: false],
  pubsub_server: Relay.PubSub

config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: {:all_except, [:conn, :crash_reason]},
     redactors: [
       {Relay.LogRedactor, []},
       {LoggerJSON.Redactors.RedactKeys,
        ["password", "secret", "token", "authorization", "cookie", "api_key", "private_key"]}
     ]}

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, {:keep, []}

config :tzdata, :autoupdate, :disabled
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

import_config "#{config_env()}.exs"
