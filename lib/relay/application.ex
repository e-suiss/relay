defmodule Relay.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Platform.Leadership,
      Relay.Tenancy,
      Relay.Keys.Eviction,
      Relay.Datasets,
      RelayWeb
    ]

  use Application

  require Logger

  @max_heap_words 32_000_000

  @impl true
  def start(_type, _args) do
    :ok = Relay.Hygiene.install_log_filter()
    Relay.Config.validate!()
    roles = Relay.Role.configured()
    :logger.update_primary_config(%{metadata: %{role: Enum.join(roles, ",")}})
    observe_heap_size()
    log_vm_topology()
    Relay.Platform.attach_telemetry()

    children =
      [Relay.Config.SecretFiles] ++
        Relay.Config.startup_probes() ++
        [RelayWeb.Telemetry] ++
        RelayWeb.Metrics.children() ++
        [
          Relay.Repo,
          {Phoenix.PubSub, name: Relay.PubSub},
          {Task.Supervisor, name: Relay.TaskSupervisor}
        ] ++
        Relay.Keys.children() ++
        Relay.Platform.children() ++
        Relay.Tenancy.children() ++
        [Relay.Keys.Eviction] ++
        Relay.Datasets.children() ++
        Relay.Platform.Leadership.children(roles) ++ [RelayWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RelayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # T-83
  defp observe_heap_size do
    :erlang.system_flag(:max_heap_size, %{size: @max_heap_words, kill: false, error_logger: true})
  end

  # T-44
  # TP-43
  defp log_vm_topology do
    Logger.info("vm topology",
      schedulers: System.schedulers(),
      schedulers_online: System.schedulers_online(),
      dirty_cpu_schedulers_online: :erlang.system_info(:dirty_cpu_schedulers_online),
      otp_release: System.otp_release(),
      tzdata_version: Tzdata.tzdata_version(),
      distribution: Node.alive?()
    )
  end
end
