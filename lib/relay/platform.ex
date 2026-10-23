defmodule Relay.Platform do
  @moduledoc """
  Platform components shared by the contexts: Valkey, signals, rate limiting, fairness, lanes and queue components. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Platform.Outbox
  alias Relay.Platform.OutboxDispatcher
  alias Relay.Platform.OutboxStore
  alias Relay.Platform.Queue
  alias Relay.Platform.Signal
  alias Relay.Platform.Store
  alias Relay.Platform.Valkey

  # T-63 (6)
  # TN-66 (4)
  @doc "Checks the dependencies a node needs to serve traffic: PostgreSQL and the key store."
  @spec readiness() :: :ok | {:error, Relay.Error.t()}
  def readiness do
    with {:database, :ok} <- {:database, Store.ping()},
         {:key_store, :ok} <- {:key_store, Relay.Keys.ping()} do
      :ok
    else
      {:database, {:error, reason}} ->
        {:error, Relay.Error.new(:not_ready, "database unavailable", %{reason: reason})}

      {:key_store, {:error, %Relay.Error{code: code}}} ->
        {:error, Relay.Error.new(:not_ready, "key store unavailable", %{reason: code})}
    end
  end

  # T-7
  # T-55
  # TN-14
  # OP-12
  # T-86
  # OP-11
  # OP-69 (1)
  @doc "Supervised children of the platform: the database role check, the `relay_ops` ownership check, the query statistics check, the Valkey adapter, its guard, the signal hub and the job queue; a worker node also runs the queue maintenance connection and the outbox dispatcher. A failed role or ownership check stops the node."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    valkey = Application.fetch_env!(:relay, Valkey)
    worker? = Relay.Role.enabled?(:worker)

    [
      Store.role_check_child(),
      Store.ops_owner_check_child(),
      Store.query_stats_check_child(),
      {Keyword.fetch!(valkey, :adapter), Keyword.delete(valkey, :adapter)},
      Valkey.Guard,
      Signal.Hub
    ] ++
      if(worker?, do: [Relay.QueueRepo], else: []) ++
      [{Oban, Queue.configured_options()}] ++
      if(worker? and outbox_dispatcher?(), do: [OutboxDispatcher], else: [])
  end

  # INV-53
  @doc "Wakes the outbox dispatchers; call it after a transaction that appended outbox rows commits."
  @spec wake_outbox() :: :ok | {:error, Relay.Error.t()}
  def wake_outbox, do: Outbox.wake()

  # OP-5
  # OP-7
  @doc "Dispatches one batch of a scope's pending outbox rows; see `Relay.Platform.Outbox.dispatch/2`."
  @spec dispatch_outbox(Relay.Scope.t(), [Outbox.option()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def dispatch_outbox(scope, opts \\ []), do: Outbox.dispatch(scope, opts)

  # C-71
  # OP-5
  @doc "Takes the next sequence number of a stream in its own scoped transaction."
  @spec next_stream_seq(Relay.Scope.t(), String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def next_stream_seq(scope, stream_key),
    do: OutboxStore.in_scope(scope, fn _status -> OutboxStore.stream_next_seq(stream_key) end)

  defp outbox_dispatcher?,
    do: :relay |> Application.get_env(Outbox, []) |> Keyword.get(:dispatcher, true)

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
