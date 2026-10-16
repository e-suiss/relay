defmodule Relay.Platform.Queue do
  @moduledoc """
  Job queue setup on open-source Oban. Every role starts an Oban instance so that jobs can be inserted inside the writing transaction; only the `worker` role runs queues, plugins and leadership. The queue's cross-node notifications travel through `Relay.Platform.Queue.Notifier`, and a switch to polling raises an alarm.
  """

  require Logger

  @handler "relay-queue-alarm"
  @events [[:oban, :notifier, :switch], [:oban, :stager, :switch]]

  # T-14
  # T-17
  # T-12
  @doc "Builds the Oban options for the roles this node runs."
  @spec options(keyword(), [Relay.Role.t()]) :: keyword()
  def options(base, roles) when is_list(base) and is_list(roles) do
    if :worker in roles,
      do: base,
      else: Keyword.merge(base, queues: [], plugins: [], peer: false)
  end

  @doc "Returns the configured Oban options for this node."
  @spec configured_options() :: keyword()
  def configured_options,
    do: options(Application.fetch_env!(:relay, Oban), Relay.Role.configured())

  # T-17
  @doc "Attaches the telemetry handler that reports a switch to polling."
  @spec attach_alarm() :: :ok | {:error, :already_exists}
  def attach_alarm, do: :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)

  @doc "Telemetry handler for notifier and stager mode switches."
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:oban, :notifier, :switch], _measurements, %{status: :isolated}, _config),
    do: Logger.error("queue notifier isolated; the queue falls back to polling")

  def handle_event([:oban, :stager, :switch], _measurements, %{mode: :local}, _config),
    do: Logger.error("queue stager switched to local polling")

  def handle_event([:oban, _, :switch], _measurements, meta, _config) do
    Logger.info("queue notification mode changed",
      status: Map.get(meta, :status),
      mode: Map.get(meta, :mode)
    )
  end
end
