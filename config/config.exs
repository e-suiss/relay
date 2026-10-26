import Config

config :relay,
  ecto_repos: [Relay.Repo],
  roles: [:api, :worker, :socket],
  clock: Relay.Clock.System,
  random: Relay.Random.Strong,
  keys: Relay.Keys.Port,
  key_provider: Relay.Tenancy.Keyring

config :relay, Relay.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :relay, Relay.Platform.Valkey,
  adapter: Relay.Platform.Valkey.Redix,
  url: "redis://localhost:6379"

config :relay, Relay.Platform.Signal, poll_interval_ms: 1_000

config :relay, Relay.Platform.Leadership,
  enabled: true,
  tasks: [
    {"partition_maintenance", Relay.Platform.Maintenance.PartitionTask, []},
    {"integrity_check", Relay.Platform.Maintenance.IntegrityTask, []},
    {"audit_checkpoint", Relay.Audit.Checkpointer, [sensitive: true]},
    {"audit_verify", Relay.Audit.Checkpointer.Verifier, [sensitive: true]},
    {"retention_sweep", Relay.Tenancy.Retention, []},
    {"dataset_packages", Relay.Datasets.PackageTask, []},
    {"projection_rebuild", Relay.Delivery.ProjectionRebuild, []},
    {"audit_readback", Relay.Audit.Checkpointer.Readback, [sensitive: true]},
    {"drr_dispatcher", Relay.Platform.Fairness.Dispatcher, []},
    {"load_shed_controller", Relay.Platform.LoadShed.Controller, []},
    {"kill_switch_paused_expiry", Relay.Tenancy.KillSwitch.Expiry, []}
  ]

config :relay, Relay.Audit,
  log_host: "localhost",
  checkpoint_key: "audit-checkpoint",
  publishers: []

config :relay, Oban,
  repo: Relay.Repo,
  prefix: "relay_queue",
  notifier: Relay.Platform.Queue.Notifier,
  peer: Relay.Platform.Queue.Peer,
  stager: [interval: 1_000],
  plugins: [
    {Oban.Lifeline, rescue_after: 7_200_000},
    Relay.Platform.Queue.Pruner,
    {Oban.Plugins.Cron, crontab: [{"*/5 * * * *", Relay.Agents.WaitpointSweep}]}
  ]

config :relay, Relay.Platform.VirtualClock, due: [{Relay.Agents, :run_due, []}]

config :relay, Relay.Platform.Outbox, dispatcher: true

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
