defmodule Relay.Platform do
  @moduledoc """
  Platform components shared by the contexts: Valkey, signals, rate limiting, fairness, lanes and queue components. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Platform.Admission
  alias Relay.Platform.Backend
  alias Relay.Platform.Concurrency
  alias Relay.Platform.Fairness.Job
  alias Relay.Platform.Fairness.Queueing
  alias Relay.Platform.Fanout
  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed
  alias Relay.Platform.Outbox
  alias Relay.Platform.OutboxDispatcher
  alias Relay.Platform.OutboxStore
  alias Relay.Platform.Queue
  alias Relay.Platform.RateLimit
  alias Relay.Platform.Signal
  alias Relay.Platform.Store
  alias Relay.Platform.Valkey
  alias Relay.Platform.VirtualClock

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
  # T-9 (5)
  # OP-11
  # OP-69 (1)
  # T-32 (3)
  # T-34
  @doc "Supervised children of the platform: the database role check, the `relay_ops` ownership check, the query statistics check, the Valkey adapter, its guard, the limit backend selector, the node's credit block table, the concurrency slot keeper, the signal hub, the load shedding watcher and the job queue; a worker node also runs the queue maintenance connection, the bulk write pool with its own role check and the outbox dispatcher. A failed role or ownership check stops the node."
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
      Backend,
      RateLimit.CreditLease,
      Concurrency.Keeper,
      Signal.Hub
    ] ++
      if(load_shed_watcher?(), do: [LoadShed.Watcher], else: []) ++
      if(worker?,
        do: [Relay.QueueRepo, Relay.BulkRepo, Store.bulk_role_check_child()],
        else: []
      ) ++
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

  defp load_shed_watcher?,
    do: :relay |> Application.get_env(LoadShed, []) |> Keyword.get(:watcher, true)

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

  # T-9
  @doc "Builds a system signal topic from fixed segments; no tenant name can reach it."
  @spec system_signal_topic([String.t(), ...]) :: Signal.topic()
  def system_signal_topic(segments),
    do: Relay.Platform.Valkey.Key.system_channel(["signal" | segments])

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

  # T-31
  # INV-16
  @doc "The lane of a message class; nothing but the class decides it."
  @spec lane(Lane.message_class()) :: Lane.t()
  def lane(message_class), do: Lane.of(message_class)

  # T-36
  @doc "The priority of a job inside its lane's queue; see `Relay.Platform.Lane.priority/3`."
  @spec job_priority(Lane.job_kind(), pos_integer(), Lane.requested_priority()) :: 0..8
  def job_priority(kind, attempt_no, requested), do: Lane.priority(kind, attempt_no, requested)

  # T-21 (2)
  # T-21 (4)
  # TN-54
  @doc """
  Puts a job into its lane inside the caller's scoped transaction: `l0` and `l1` jobs go to their queue at once, `l2` and `l3` jobs to the tenant wait table in front of it. `attrs` holds `:id` (a fresh UUIDv7), `:lane`, `:worker`, `:args` (identifiers only), `:ref_kind`, `:ref_id`, and optionally `:priority`, `:cost` and `:scheduled_at`; `:queued_cap` in `opts` limits the tenant's waiting jobs in the lane.
  """
  @spec enqueue_job(keyword() | map(), keyword()) ::
          {:ok, :queued | :waiting | :exists} | {:error, Relay.Error.t()}
  def enqueue_job(attrs, opts \\ []), do: Queueing.enqueue(struct!(Job, attrs), opts)

  # T-21 (3)
  @doc "Marks the waiting jobs behind a record `cancelled` inside the caller's scoped transaction, with the rule that cancelled them."
  @spec cancel_waiting_jobs(String.t(), Relay.Id.t(), String.t()) :: {:ok, non_neg_integer()}
  def cancel_waiting_jobs(ref_kind, ref_id, rule_id),
    do: Queueing.cancel(ref_kind, ref_id, rule_id)

  # T-21 (2)
  # T-12
  @doc "One step of the DRR dispatcher under its fencing token; see `Relay.Platform.Fairness.Queueing.step/3`."
  @spec fair_dispatch_step(pos_integer(), integer() | nil, integer()) ::
          {:ok, Queueing.step_result()} | :not_leader | {:error, Relay.Error.t()}
  def fair_dispatch_step(fencing_token, weights_at, now_ms),
    do: Queueing.step(fencing_token, weights_at, now_ms)

  # T-34
  # T-12
  @doc "One step of the load shedding controller under its fencing token; returns the task state to save."
  @spec load_shed_step(pos_integer(), map() | nil) ::
          {:ok, map()} | :not_leader | {:error, Relay.Error.t()}
  def load_shed_step(fencing_token, saved), do: LoadShed.Control.step(fencing_token, saved)

  # T-34 (2)
  @doc "True while load shedding is engaged for the lane on this node's last known state."
  @spec load_shed_engaged?(Lane.t()) :: boolean()
  def load_shed_engaged?(lane), do: LoadShed.engaged?(lane)

  # T-34 (2)
  # T-34 (4)
  # INV-24
  @doc "Decides whether a starting delivery job runs or is postponed by load shedding; see `Relay.Platform.LoadShed.hold/5`."
  @spec load_shed_hold(Relay.Scope.t(), Lane.t(), Relay.Id.t(), non_neg_integer()) ::
          LoadShed.hold_result()
  def load_shed_hold(scope, lane, delivery_id, k), do: LoadShed.hold(scope, lane, delivery_id, k)

  # API-51
  # T-35
  # T-92
  @doc "Admission control for an incoming request; see `Relay.Platform.Admission.decide/1`."
  @spec admit(Admission.input()) :: :admit | {:reject, Admission.rejection()}
  def admit(input), do: Admission.decide(input)

  # T-32 (3)
  @doc "Runs `fun` on the database pool of a lane: the OLTP pool for `l0` and `l1`, the bulk pool for `l2` and `l3`."
  @spec with_lane_pool(Lane.t(), (-> result)) :: result when result: term()
  def with_lane_pool(lane, fun) when is_function(fun, 0) do
    case Lane.pool(lane) do
      :oltp -> fun.()
      :bulk -> Relay.BulkRepo.run(fun)
    end
  end

  # T-19
  # T-20 (6)
  # CH-17
  @doc "Builds a rate limit definition; see `Relay.Platform.RateLimit.Limit.new/1`."
  @spec rate_limit(map() | keyword()) :: {:ok, RateLimit.Limit.t()} | {:error, Relay.Error.t()}
  def rate_limit(attrs), do: RateLimit.Limit.new(attrs)

  # T-19
  # T-20
  # INV-44
  @doc "Decides one rate-limited request; see `Relay.Platform.RateLimit.check/6`."
  @spec rate_limit_check(
          Relay.Scope.t(),
          RateLimit.Limit.t(),
          [String.t()],
          pos_integer(),
          RateLimit.lane(),
          [RateLimit.option()]
        ) :: RateLimit.decision()
  def rate_limit_check(scope, limit, key_parts, cost, lane, opts \\ []),
    do: RateLimit.check(scope, limit, key_parts, cost, lane, opts)

  # T-27
  @doc "Adds to or reads a sliding counter; see `Relay.Platform.RateLimit.counter/6`."
  @spec rate_counter(Relay.Scope.t(), String.t(), pos_integer(), :incr | :read, non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def rate_counter(scope, limit_key, window_ms, op, by),
    do: RateLimit.counter(scope, limit_key, window_ms, op, by)

  # TN-43
  @doc "Adds to a minute bucket ring; see `Relay.Platform.RateLimit.ring/6`."
  @spec rate_ring(
          Relay.Scope.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, Relay.Error.t()}
  def rate_ring(scope, limit_key, cost, current, baseline),
    do: RateLimit.ring(scope, limit_key, cost, current, baseline)

  # T-20 (5)
  # T-91 (1)
  @doc "The default credit lease of a channel; see `Relay.Platform.RateLimit.CreditLease.default/2`."
  @spec credit_lease_default(String.t(), pos_integer()) :: RateLimit.CreditLease.lease()
  def credit_lease_default(channel, burst), do: RateLimit.CreditLease.default(channel, burst)

  # T-22
  @doc "Takes a cluster-wide concurrency slot; see `Relay.Platform.Concurrency.acquire/5`."
  @spec concurrency_acquire(Relay.Scope.t(), String.t(), pos_integer(), String.t()) ::
          Concurrency.result()
  def concurrency_acquire(scope, counter_key, limit, holder),
    do: Concurrency.acquire(scope, counter_key, limit, holder)

  @doc "Releases a cluster-wide concurrency slot; see `Relay.Platform.Concurrency.release/4`."
  @spec concurrency_release(Relay.Scope.t(), String.t(), String.t()) :: :ok
  def concurrency_release(scope, counter_key, holder),
    do: Concurrency.release(scope, counter_key, holder)

  # T-22
  @doc "Runs work while holding a concurrency slot; see `Relay.Platform.Concurrency.with_slot/6`."
  @spec with_concurrency_slot(Relay.Scope.t(), String.t(), pos_integer(), String.t(), (-> term())) ::
          {:ok, term()} | {:full, non_neg_integer()}
  def with_concurrency_slot(scope, counter_key, limit, holder, fun),
    do: Concurrency.with_slot(scope, counter_key, limit, holder, fun)

  # T-22
  # T-30
  @doc "The snooze in seconds of a job that found its limit full; see `Relay.Platform.Concurrency.snooze_seconds/4`."
  @spec concurrency_snooze(Relay.Scope.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          pos_integer()
  def concurrency_snooze(scope, job_ref, k, wait_ms),
    do: Concurrency.snooze_seconds(scope, job_ref, k, wait_ms)

  # T-91 (1)
  @doc "The default concurrency limit of a counter family."
  @spec concurrency_default(:tenant_channel | :tenant_deliveries) :: pos_integer()
  def concurrency_default(family), do: Concurrency.default_limit(family)

  # T-23
  @doc "Creates a fan-out and queues its slice jobs; see `Relay.Platform.Fanout.create/2`."
  @spec create_fanout(Relay.Scope.t(), map()) :: {:ok, term()} | {:error, term()}
  def create_fanout(scope, attrs), do: Fanout.create(scope, attrs)

  # T-34
  @doc "Pauses a fan-out under a rule; see `Relay.Platform.Fanout.pause/3`."
  @spec pause_fanout(Relay.Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, atom()} | {:error, term()}
  def pause_fanout(scope, fanout_id, rule_id),
    do: Fanout.pause(scope, fanout_id, rule_id)

  @doc "Resumes a paused fan-out; see `Relay.Platform.Fanout.resume/2`."
  @spec resume_fanout(Relay.Scope.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def resume_fanout(scope, fanout_id), do: Fanout.resume(scope, fanout_id)

  # T-23 (4)
  @doc "Cancels a fan-out; see `Relay.Platform.Fanout.cancel/5`."
  @spec cancel_fanout(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, tuple()} | {:error, term()}
  def cancel_fanout(scope, fanout_id, rule_id, record_digest, actor),
    do: Fanout.cancel(scope, fanout_id, rule_id, record_digest, actor)

  # T-23 (6)
  @doc "Reads a fan-out's progress."
  @spec get_fanout(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_fanout(scope, fanout_id), do: Fanout.get(scope, fanout_id)

  # TN-8
  # X-27
  @doc "Advances the virtual clock of a `test` scope; see `Relay.Platform.VirtualClock.advance/4`."
  @spec advance_virtual_clock(Relay.Scope.t(), integer(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, term()} | {:error, Relay.Error.t()}
  def advance_virtual_clock(scope, by_ms, record_digest, actor),
    do: VirtualClock.advance(scope, by_ms, record_digest, actor)

  # X-27
  @doc "Reads the virtual clock of a scope; `live` answers `:not_test_environment`."
  @spec virtual_clock(Relay.Scope.t()) :: {:ok, term()} | {:error, term()}
  def virtual_clock(scope), do: VirtualClock.get(scope)
end
