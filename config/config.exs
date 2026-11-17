import Config

config :relay,
  ecto_repos: [Relay.Repo],
  roles: [:api, :worker, :socket],
  clock: Relay.Clock.System,
  random: Relay.Random.Strong,
  keys: Relay.Keys.Port,
  key_provider: Relay.Tenancy.Keyring

config :swoosh, api_client: false, local: false

config :relay, Relay.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :relay, Relay.Platform.Valkey,
  adapter: Relay.Platform.Valkey.Redix,
  url: "redis://localhost:6379"

config :relay, Relay.Platform.Signal, poll_interval_ms: 1_000

config :relay, Relay.Platform.Fanout, sources: %{"campaign" => Relay.Api.Campaigns.SendSource}

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
    {"failure_actor_backfill", Relay.Delivery.FailureActorBackfill, []},
    {"correlation_digest_backfill", Relay.Agents.CorrelationDigestBackfill, []},
    {"audit_readback", Relay.Audit.Checkpointer.Readback, [sensitive: true]},
    {"drr_dispatcher", Relay.Platform.Fairness.Dispatcher, []},
    {"load_shed_controller", Relay.Platform.LoadShed.Controller, []},
    {"kill_switch_paused_expiry", Relay.Tenancy.KillSwitch.Expiry, []},
    {"access_link_refresh", Relay.Access.Refresh, []},
    {"tenant_suspension_activator", Relay.Operators.SuspensionActivator, []},
    {"observability_rollup", Relay.Observability.Rollup, []},
    {"inbox_maintenance", Relay.Inbox.Maintenance, []},
    {"webhook_maintenance", Relay.Webhooks.Maintenance, []}
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
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Relay.Agents.WaitpointSweep},
       {"*/5 * * * *", Relay.Api.Recurrences.Sweep},
       {"*/5 * * * *", Relay.Workflow.Digest.Sweep},
       {"* * * * *", Relay.Workflow.RunSweep},
       {"*/5 * * * *", Relay.Delivery.WindowSweep},
       {"17 * * * *", Relay.Devices.Sweep},
       {"20 0 * * *", Relay.Delivery.UsageDay},
       {"13 * * * *", Relay.Delivery.ReportRollup},
       {"40 2 * * *", Relay.Delivery.ReportRollup, args: %{"days" => 15}},
       {"41 * * * *", Relay.Channels.Live.SettingsSweep},
       {"*/5 * * * *", Relay.Channels.Live.ReconcileSweep},
       {"* * * * *", Relay.Channels.Live.SesQueue},
       {"* * * * *", Relay.Webhooks.Sweep},
       {"*/15 * * * *", Relay.Iys.Sweep},
       {"*/5 * * * *", Relay.Iys.SyncSweep},
       {"53 * * * *", Relay.Access.Pairing.Job}
     ]}
  ]

config :relay, Relay.Platform.VirtualClock,
  due: [
    {Relay.Agents, :run_due, []},
    {Relay.Delivery.WindowSweep, :run_due, []},
    {Relay.Api.Recurrences, :run_due, []},
    {Relay.Workflow, :run_due_digests, []},
    {Relay.Workflow, :run_due, []}
  ]

config :relay, Relay.Workflow,
  resumer: Relay.Api.WorkflowRuns,
  waiter: Relay.Agents,
  emitter: Relay.Webhooks

config :relay, Relay.Workflow.Digest, sink: Relay.Workflow, release: Relay.Policy.Live

config :relay, Relay.Agents,
  waitpoint_sink: Relay.Workflow,
  invitation_sink: Relay.Agents.Live,
  wake_transports: [Relay.Webhooks.Live.A2aPush]

config :relay, Relay.Templates.Live, planless: Relay.Agents.Live

config :relay, Relay.Platform.Outbox,
  dispatcher: true,
  handler: {Relay.Webhooks.Live, :outbox_jobs}

config :relay, Relay.Access,
  subscriber_token_key: "subscriber-token",
  client_key: "access-client",
  pep_key: "access-pep",
  service_key: "access-service",
  event_receiver: "https://localhost/v1/access/events",
  autoload: true,
  user_handlers: [Relay.Operators.AccessUserHandler, Relay.Operators.AccessSubscriberHandler],
  agent_handlers: [Relay.Operators.AccessAgentHandler],
  decision_handler: Relay.Operators.AccessDecisionHandler,
  consent_handler: Relay.Preferences.AccessConsentHandler,
  relationship_handler: Relay.Operators.AccessRelationshipHandler

config :relay, Relay.Iys, runtime: Relay.Iys.Live

config :relay, Relay.Policy.IysGate, impl: Relay.Iys.Gate

config :relay, Relay.Preferences, consent_sink: Relay.Iys.Live

config :relay, Relay.Compliance,
  refusals: Relay.Compliance.Refusals,
  sink: Relay.Iys.Live,
  unsubscribe_key: "unsubscribe-link",
  unsubscribe_verify_keys: [],
  unsubscribe_mailbox: "unsubscribe@localhost"

config :relay, Relay.Channels, unsubscribe: Relay.Compliance.Refusals

config :relay, RelayWeb.Links, handler: RelayWeb.Links.Unsubscribe

config :relay, RelayWeb.Auth, verifier: RelayWeb.Auth.Access

config :relay, RelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: RelayWeb.ErrorJSON], layout: false],
  pubsub_server: Relay.PubSub,
  live_view: [signing_salt: "relay operator panel"]

config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: {:all_except, [:conn, :crash_reason]},
     redactors: [
       {Relay.LogRedactor, []},
       {LoggerJSON.Redactors.RedactKeys,
        ["password", "secret", "token", "authorization", "cookie", "api_key", "private_key"]}
     ]}

config :oban_met,
  reporter: [auto_migrate: false, estimate_limit: :infinity, check_interval: 15_000]

config :relay, Relay.Operators.Access, adapter: Relay.Operators.Access.Unconfigured

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, {:keep, []}

config :tzdata, :autoupdate, :disabled
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :ex_cldr, default_backend: Relay.Templates.Cldr

import_config "#{config_env()}.exs"
