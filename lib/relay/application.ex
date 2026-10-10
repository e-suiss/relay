defmodule Relay.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform, RelayWeb]
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Relay.Config.validate!()
    roles = Relay.Role.configured()
    :logger.update_primary_config(%{metadata: %{role: Enum.join(roles, ",")}})
    log_vm_topology()

    children = [
      RelayWeb.Telemetry,
      Relay.Repo,
      {Phoenix.PubSub, name: Relay.PubSub},
      {Task.Supervisor, name: Relay.TaskSupervisor},
      RelayWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RelayWeb.Endpoint.config_change(changed, removed)
    :ok
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
