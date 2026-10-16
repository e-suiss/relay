defmodule Relay.Platform do
  @moduledoc """
  Platform components shared by the contexts: Valkey, signals, rate limiting, fairness, lanes and queue components. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Platform.Queue
  alias Relay.Platform.Signal
  alias Relay.Platform.Store
  alias Relay.Platform.Valkey

  # T-63
  @doc "Checks the dependencies a node needs to serve traffic."
  @spec readiness() :: :ok | {:error, Relay.Error.t()}
  def readiness do
    case Store.ping() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Relay.Error.new(:not_ready, "database unavailable", %{reason: reason})}
    end
  end

  # T-7
  # T-55
  @doc "Supervised children of the platform: the Valkey adapter, its guard, the signal hub and the job queue."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    valkey = Application.fetch_env!(:relay, Valkey)

    [
      {Keyword.fetch!(valkey, :adapter), Keyword.delete(valkey, :adapter)},
      Valkey.Guard,
      Signal.Hub,
      {Oban, Queue.configured_options()}
    ]
  end

  # T-17
  @doc "Attaches the platform's telemetry alarms; call once before the supervision tree starts."
  @spec attach_telemetry() :: :ok
  def attach_telemetry do
    _ = Queue.attach_alarm()
    :ok
  end

  # TN-17
  @doc "Builds a tenant-scoped signal topic."
  @spec signal_topic(String.t(), String.t(), [String.t(), ...]) ::
          {:ok, Signal.topic()} | {:error, Relay.Error.t()}
  def signal_topic(tenant_id, environment, segments),
    do: Signal.topic(tenant_id, environment, segments)

  # INV-52
  # INV-53
  @doc "Publishes a signal with only a sequence number; call it after the transaction commits."
  @spec publish_signal(Signal.topic(), non_neg_integer()) :: :ok | {:error, Relay.Error.t()}
  def publish_signal(topic, seq), do: Signal.publish(topic, seq)

  # T-9 (3)
  @doc "Subscribes the calling process to a signal topic; see `Relay.Platform.Signal` for the messages."
  @spec subscribe_signal(Signal.topic()) :: :ok
  def subscribe_signal(topic), do: Signal.subscribe(topic)

  @doc "Unsubscribes the calling process from a signal topic."
  @spec unsubscribe_signal(Signal.topic()) :: :ok
  def unsubscribe_signal(topic), do: Signal.unsubscribe(topic)
end
