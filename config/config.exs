import Config

config :relay,
  ecto_repos: [Relay.Repo],
  roles: [:api, :worker, :socket],
  clock: Relay.Clock.System,
  random: Relay.Random.Strong

config :relay, Relay.Repo,
  migration_primary_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

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
