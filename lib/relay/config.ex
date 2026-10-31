defmodule Relay.Config do
  @moduledoc """
  Strict configuration validation run before the supervision tree starts. An unknown configuration key, an unknown role or an unknown `RELAY_` environment variable stops the node; there is no silent default and no key that weakens a security or compliance check.
  """

  require Logger

  alias Relay.Config.Error

  @app_keys [
    :ecto_repos,
    :roles,
    :clock,
    :random,
    :keys,
    :key_provider,
    Relay.Keys,
    Relay.Keys.Port,
    Relay.Repo,
    RelayWeb.Endpoint,
    Relay.Platform.Valkey,
    Relay.Platform.Signal,
    Relay.Platform.Outbox,
    Relay.Platform.VirtualClock,
    Relay.Platform.Fanout,
    Relay.QueueRepo,
    Relay.BulkRepo,
    Relay.Platform.LoadShed,
    Relay.Platform.Capacity,
    Relay.Platform.MaintRepo,
    Relay.Platform.Leadership,
    Relay.Delivery,
    Relay.Audit,
    Relay.NetworkGuard,
    Relay.Config.SecretFiles,
    Relay.Tenancy.KillSwitch.Cache,
    Relay.Policy.Lattice,
    RelayWeb.Metrics,
    RelayWeb.Api,
    RelayWeb.Auth,
    Relay.Access,
    Relay.Operators,
    Relay.Operators.Access,
    Relay.Connectors,
    Oban
  ]
  @repos [Relay.Repo, Relay.QueueRepo, Relay.BulkRepo, Relay.Platform.MaintRepo]
  @os_env_keys ["RELAY_HOST", "RELAY_ROLES", "RELAY_REGION", "RELAY_ACCESS_ISSUER"]
  @audit_keys [:log_host, :checkpoint_key, :publishers]
  @production Mix.env() == :prod

  # INV-46
  # TN-8
  # OP-70
  @doc "Validates application configuration and the process environment; raises `Relay.Config.Error` on any unknown key or role. A production build (`production?: true`) also requires an audit checkpoint target independent of Relay's own operation."
  @spec validate!(keyword(), %{optional(String.t()) => String.t()}, keyword()) :: :ok
  def validate!(
        app_env \\ Application.get_all_env(:relay),
        os_env \\ System.get_env(),
        opts \\ [production?: @production]
      ) do
    validate_app_keys!(app_env)
    validate_roles!(Keyword.get(app_env, :roles))
    validate_key_store!(Keyword.get(app_env, Relay.Keys.Port))
    validate_key_labels!(Keyword.get(app_env, Relay.Keys))
    production? = Keyword.get(opts, :production?, true)
    validate_audit!(Keyword.get(app_env, Relay.Audit), production?)
    validate_secret_files!(Keyword.get(app_env, Relay.Config.SecretFiles, []))
    if production?, do: validate_no_plain_secrets!(app_env)
    validate_os_env!(os_env)
    :ok
  end

  # OP-71 (6)
  # OP-70
  @doc "Startup probes of a production node: one child per audit publication target that can be probed. Each writes and reads back a probe object when the node starts; a failed probe stops the node."
  @spec startup_probes(boolean()) :: [Supervisor.child_spec()]
  def startup_probes(production? \\ @production)

  def startup_probes(true) do
    for {target, module, opts} <- publishers(), exported?(module, :probe, 1) do
      %{
        id: {:audit_target_probe, target},
        start: {__MODULE__, :probe, [target, module, opts]},
        restart: :temporary
      }
    end
  end

  def startup_probes(false), do: []

  # OP-71 (6)
  @doc "Runs the startup probe of one audit publication target; returns `:ignore` when it passed, so the supervisor moves on."
  @spec probe(String.t(), module(), keyword()) :: :ignore | {:error, term()}
  def probe(target, module, opts) do
    case module.probe(opts) do
      :ok ->
        :ignore

      {:error, %Relay.Error{code: code}} ->
        Logger.error("audit publication target probe failed", target: target, code: code)
        {:error, {:audit_target_probe_failed, target, code}}
    end
  end

  defp publishers,
    do: :relay |> Application.get_env(Relay.Audit, []) |> Keyword.get(:publishers, [])

  # TN-67 (3)
  defp validate_secret_files!(paths) do
    names = Relay.Config.SecretFiles.names()

    valid? =
      Keyword.keyword?(paths) and
        Enum.all?(paths, fn {name, path} -> name in names and is_binary(path) and path != "" end)

    if valid?,
      do: :ok,
      else: raise(Error, "Relay.Config.SecretFiles takes #{inspect(names)} mapped to file paths")
  end

  # TN-67 (3)
  # TN-68 (1)
  # TN-26 (4)
  defp validate_no_plain_secrets!(app_env) do
    for repo <- @repos, Keyword.has_key?(Keyword.get(app_env, repo) || [], :password) do
      raise Error, "#{inspect(repo)} must take its password from Relay.Config.SecretFiles"
    end

    if Keyword.has_key?(Keyword.get(app_env, RelayWeb.Endpoint) || [], :secret_key_base),
      do:
        raise(
          Error,
          "RelayWeb.Endpoint must take secret_key_base from Relay.Config.SecretFiles"
        )

    audit = Keyword.get(app_env, Relay.Audit) || []

    for {target, _module, opts} <- Keyword.get(audit, :publishers, []),
        Keyword.has_key?(opts, :secret_access_key),
        not callback?(opts[:secret_access_key]) do
      raise Error, "audit publisher #{target} must take its secret from Relay.Config.SecretFiles"
    end

    :ok
  end

  defp callback?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp callback?(_value), do: false

  @doc "Configuration keys the application recognises."
  @spec known_app_keys() :: [atom()]
  def known_app_keys, do: @app_keys

  @doc "`RELAY_` environment variables the application recognises."
  @spec known_os_env_keys() :: [String.t()]
  def known_os_env_keys, do: @os_env_keys

  defp validate_app_keys!(app_env) do
    case Keyword.keys(app_env) -- @app_keys do
      [] ->
        :ok

      unknown ->
        raise Error, "unknown configuration keys for :relay: #{inspect(Enum.sort(unknown))}"
    end
  end

  defp validate_roles!(roles) when is_list(roles) and roles != [] do
    cond do
      Enum.uniq(roles) != roles ->
        raise Error, "duplicate roles: #{inspect(roles)}"

      (unknown = roles -- Relay.Role.all()) != [] ->
        raise Error, "unknown roles: #{inspect(unknown)}"

      true ->
        :ok
    end
  end

  defp validate_roles!(roles),
    do: raise(Error, "roles must be a non-empty list, got: #{inspect(roles)}")

  # TN-63
  defp validate_key_store!(nil), do: :ok

  defp validate_key_store!(opts) when is_list(opts) do
    keys = Relay.Keys.port_config_keys()

    cond do
      not Keyword.keyword?(opts) ->
        raise Error, "Relay.Keys.Port configuration must be a keyword list"

      (unknown = Keyword.keys(opts) -- keys) != [] ->
        raise Error, "unknown Relay.Keys.Port configuration keys: #{inspect(Enum.sort(unknown))}"

      (missing = Enum.reject(keys, &is_binary(opts[&1]))) != [] ->
        raise Error, "Relay.Keys.Port configuration is missing #{inspect(missing)}"

      true ->
        :ok
    end
  end

  defp validate_key_store!(opts),
    do:
      raise(Error, "Relay.Keys.Port configuration must be a keyword list, got: #{inspect(opts)}")

  # TN-67 (1)
  # TN-67 (4)
  defp validate_key_labels!(nil), do: :ok

  defp validate_key_labels!(opts) when is_list(opts) do
    keys = Relay.Keys.label_config_keys()

    cond do
      not Keyword.keyword?(opts) ->
        raise Error, "Relay.Keys configuration must be a keyword list"

      (unknown = Keyword.keys(opts) -- keys) != [] ->
        raise Error, "unknown Relay.Keys configuration keys: #{inspect(Enum.sort(unknown))}"

      (invalid = Enum.reject(keys, &(is_binary(opts[&1]) and opts[&1] != ""))) != [] ->
        raise Error, "Relay.Keys configuration is missing #{inspect(invalid)}"

      true ->
        :ok
    end
  end

  defp validate_key_labels!(opts),
    do: raise(Error, "Relay.Keys configuration must be a keyword list, got: #{inspect(opts)}")

  # OP-63
  # OP-70
  defp validate_audit!(nil, true),
    do: raise(Error, "Relay.Audit configuration is required in production")

  defp validate_audit!(nil, false), do: :ok

  defp validate_audit!(opts, production?) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        raise Error, "Relay.Audit configuration must be a keyword list"

      (unknown = Keyword.keys(opts) -- @audit_keys) != [] ->
        raise Error, "unknown Relay.Audit configuration keys: #{inspect(Enum.sort(unknown))}"

      true ->
        publishers = Keyword.get(opts, :publishers, [])
        validate_publishers!(publishers)

        if production? and not Enum.any?(publishers, &independent?/1),
          do:
            raise(
              Error,
              "a production node needs an audit checkpoint target independent of Relay (OP-70)"
            ),
          else: :ok
    end
  end

  defp validate_audit!(opts, _production?),
    do: raise(Error, "Relay.Audit configuration must be a keyword list, got: #{inspect(opts)}")

  defp validate_publishers!(publishers) when is_list(publishers) do
    targets =
      for publisher <- publishers do
        case publisher do
          {target, module, opts} when is_binary(target) and is_atom(module) and is_list(opts) ->
            validate_publisher!(target, module, opts)
            target

          other ->
            raise Error,
                  "audit publisher must be {target, module, options}, got: #{inspect(other)}"
        end
      end

    if Enum.uniq(targets) != targets,
      do: raise(Error, "duplicate audit publication targets: #{inspect(targets)}"),
      else: :ok
  end

  defp validate_publishers!(other),
    do: raise(Error, "audit publishers must be a list, got: #{inspect(other)}")

  defp validate_publisher!(target, module, opts) do
    cond do
      not Regex.match?(~r/^(worm_store|siem|customer:[A-Za-z0-9_.-]{1,128})$/, target) ->
        raise Error, "unknown audit publication target #{inspect(target)}"

      not exported?(module, :publish, 2) ->
        raise Error, "audit publisher #{inspect(module)} is not a publisher"

      not exported?(module, :validate, 1) ->
        :ok

      true ->
        case module.validate(opts) do
          :ok -> :ok
          {:error, message} -> raise Error, "audit publisher #{target}: #{message}"
        end
    end
  end

  defp independent?({_target, module, _opts}),
    do: exported?(module, :independent?, 0) and module.independent?() == true

  defp exported?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)

  defp validate_os_env!(os_env) do
    unknown =
      os_env
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "RELAY_"))
      |> Enum.reject(&(&1 in @os_env_keys))
      |> Enum.sort()

    if unknown != [],
      do: raise(Error, "unknown environment variables: #{Enum.join(unknown, ", ")}"),
      else: :ok
  end
end
