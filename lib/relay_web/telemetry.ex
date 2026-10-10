defmodule RelayWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric definitions. Metric tags come from bounded sets only; tenant, user, device, address or identifier never become a tag.
  """

  use Supervisor

  import Telemetry.Metrics

  @doc false
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [{:telemetry_poller, measurements: [], period: 10_000}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  # T-63
  @doc "Metric definitions exported by reporters."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("relay.repo.query.total_time", unit: {:native, :millisecond}),
      summary("relay.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end
end
