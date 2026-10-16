import Config

if config_env() == :prod do
  config :relay, Relay.Repo,
    url: Relay.Config.Env.database_url!("DATABASE_URL"),
    password: Relay.Config.Env.file!("DATABASE_PASSWORD_FILE"),
    pool_size: Relay.Config.Env.integer!("POOL_SIZE")

  config :relay, Relay.Platform.Valkey,
    adapter: Relay.Platform.Valkey.Redix,
    url: Relay.Config.Env.valkey_url!("VALKEY_URL")

  config :relay, RelayWeb.Endpoint,
    url: [host: Relay.Config.Env.fetch!("RELAY_HOST"), port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: Relay.Config.Env.integer!("PORT")],
    secret_key_base: Relay.Config.Env.fetch!("SECRET_KEY_BASE")

  roles = Relay.Config.Env.roles!("RELAY_ROLES")

  if :worker in roles do
    config :relay, Relay.QueueRepo,
      url: Relay.Config.Env.database_url!("QUEUE_DATABASE_URL"),
      password: Relay.Config.Env.file!("QUEUE_DATABASE_PASSWORD_FILE"),
      pool_size: 2
  end

  config :relay, roles: roles
  config :relay, RelayWeb.Endpoint, server: :api in roles or :socket in roles
end
