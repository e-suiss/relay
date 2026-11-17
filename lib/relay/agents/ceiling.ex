defmodule Relay.Agents.Ceiling do
  @moduledoc """
  The per-agent notification ceiling (AG-48, AG-49, AG-50, C-78, INV-3, INV-34). A notification whose sender type is `agent` passes the ceiling of the agent that sent it before it is sent; notifications of human and system senders never reach it, and their frequency cap keeps its own rule. The ceiling is apart from the frequency cap and from throttle: it counts the notifications an agent sent in a rolling hour and a rolling day (`x-relay-limits` `agent_ceiling`, AG-70), which a tenant may only lower (`agents.ceiling.per_hour`, `agents.ceiling.per_day`).

  A notification is attributed to its agent when it is accepted (`attribute_here/2`, in the accepting transaction). The policy lattice step of a delivery job asks `admit/3` once the lattice decided to send:

    * A notification is decided once. Its first delivery to arrive reads the agent's counters, sliding counters of `Relay.Platform.rate_counter/5` that fall back to PostgreSQL when Valkey is away. Below the ceiling the notification is recorded as passed and counted; every later delivery of it passes without being counted again.
    * At or over the ceiling the notification is held (`agent_ceiling.exceeded`): its delivery is paused, never failed and never deleted, and the first hold of an agent opens a ceiling event and announces `agent.ceiling_exceeded` to the owner in the same transaction. Further deliveries of a held notification are paused under the same hold.
    * When neither backend can read the counters the notification is held too (`agent_ceiling.counter_unreadable`): the ceiling fails closed.
    * A stopped agent's new notifications are skipped with `agent_ceiling.stopped`.

  The owner lists the held notifications (`list_holds/5`) and decides with `decide_here/4`: `send_all` releases them, `cancel` cancels them and `stop` cancels them and stops the agent until `resume_here/4`. A release needs the reference of a step-up (TN-21) and is refused without one. The decision, the state of every held notification and the audit record are written in one transaction with the job that applies it (`Relay.Agents.Ceiling.ApplyWorker`); the job resumes, cancels or expires the paused deliveries batch by batch. A held notification keeps its `expires_at`: one that is past it when it is released is closed as `expired` with `agent_ceiling.expired` and is not sent, and the paused expiry sweep leaves held notifications alone.

  A stop is the owner's decision and is kept apart from the agent record's state, which only Access changes. Every way a notification of sender type `agent` is accepted names its agent (AG-75): a send with an agent's credential, and a decision request of a waitpoint an agent waits on; a request that states the sender type without an agent's credential is refused at acceptance. A notification of sender type `agent` that names no agent all the same is never sent: its job fails closed and retries, with `[:relay, :agents, :ceiling, :unattributed]` telemetry. `[:relay, :agents, :ceiling, :held]` counts the holds by reason.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Delivery, Relay.Platform], exports: []

  alias Relay.Actor
  alias Relay.Agents.Ceiling.ApplyWorker
  alias Relay.Agents.Ceiling.Decision
  alias Relay.Agents.Ceiling.Store
  alias Relay.Scope

  require Logger

  @hour_ms 3_600_000
  @day_ms 86_400_000
  @batch 100

  @type counter :: (Scope.t(), String.t(), pos_integer(), atom(), non_neg_integer() -> term())
  @type option :: {:counter, counter()}
  @type sender :: %{
          required(:notification_id) => Relay.Id.t(),
          required(:delivery_id) => Relay.Id.t(),
          required(:sender_type) => term()
        }
  @type admission ::
          :pass
          | :held
          | {:skip, atom(), String.t()}
          | {:expire, String.t()}
          | {:error, {:input_unavailable, :agent_ceiling}}
  @type answer :: {atom(), map() | nil}

  # AG-48
  # E-56
  # AG-75
  @doc "Attributes a notification of sender type `agent` to the agent it was accepted for, inside the accepting transaction; a notification that is already attributed keeps its agent."
  @spec attribute_here(Relay.Id.t(), Relay.Id.t()) :: :attributed | :exists | :not_found
  def attribute_here(notification_id, agent_id), do: Store.attribute(notification_id, agent_id)

  # AG-48
  # AG-49
  # AG-50
  # INV-34
  @doc """
  Passes a delivery the lattice decided to send through the ceiling of its agent. `:pass`: the notification is not an agent's, or it is below the ceiling, already passed or released; `:held`: its delivery is paused for the owner's decision; `{:skip, reason, rule_id}`: the agent is stopped or the owner cancelled the held notification; `{:expire, rule_id}`: it was released past its `expires_at`; an error when the ceiling's own records cannot be read or the notification names no agent, so that nothing is sent and the job retries. `counter: fun` replaces `Relay.Platform.rate_counter/5`.
  """
  @spec admit(Scope.t(), sender(), [option()]) :: admission()
  def admit(%Scope{} = scope, sender, opts \\ []) do
    if Decision.subject?(sender.sender_type), do: check(scope, sender, opts), else: :pass
  end

  defp check(scope, sender, opts) do
    case Store.in_scope(scope, fn _status -> Store.status(sender.notification_id) end) do
      {:ok, nil} -> unattributed()
      {:ok, status} -> known(scope, Map.put(sender, :agent_ref, status.agent_ref), status, opts)
      {:error, _reason} -> unavailable()
    end
  end

  # AG-75
  # INV-34
  defp unattributed do
    :telemetry.execute([:relay, :agents, :ceiling, :unattributed], %{count: 1}, %{})
    Logger.error("agent notification names no agent; it is not sent")
    unavailable()
  end

  defp known(_scope, _sender, %{hold_state: state}, _opts) when state in ["passed", "released"],
    do: :pass

  defp known(scope, sender, %{hold_state: "held"}, _opts),
    do: hold(scope, sender, "agent_ceiling.exceeded")

  defp known(_scope, _sender, %{hold_state: "cancelled"}, _opts), do: cancelled()
  defp known(_scope, _sender, %{hold_state: "expired"}, _opts), do: expired()
  defp known(_scope, _sender, %{stopped: true}, _opts), do: stopped()

  defp known(scope, sender, status, opts) do
    counter = Keyword.get(opts, :counter, &Relay.Platform.rate_counter/5)
    limits = Decision.limits(status.per_hour, status.per_day)

    case Decision.decide(usage(scope, sender.agent_ref, counter), limits) do
      :pass -> pass(scope, sender, counter)
      {:hold, rule_id} -> hold(scope, sender, rule_id)
    end
  end

  # AG-50
  defp usage(scope, agent_ref, counter) do
    with {:ok, hour} <- counter.(scope, key("h", agent_ref), @hour_ms, :read, 0),
         {:ok, day} <- counter.(scope, key("d", agent_ref), @day_ms, :read, 0) do
      %{hour: hour, day: day}
    else
      _unreadable ->
        Logger.error("agent ceiling counter unreadable; agent notifications are held")
        :unreadable
    end
  end

  defp key(window, agent_ref),
    do: "agent_ceiling:" <> window <> ":" <> Relay.Id.to_string(agent_ref)

  defp pass(scope, sender, counter) do
    write = fn _status -> Store.pass(sender.notification_id, sender.agent_ref) end

    case Store.in_scope(scope, write) do
      {:ok, :passed} -> counted(scope, sender.agent_ref, counter)
      {:ok, :held} -> hold(scope, sender, "agent_ceiling.exceeded")
      {:ok, :cancelled} -> cancelled()
      {:ok, :expired} -> expired()
      {:ok, _passed_released_or_gone} -> :pass
      {:error, _reason} -> unavailable()
    end
  end

  defp counted(scope, agent_ref, counter) do
    _ = counter.(scope, key("h", agent_ref), @hour_ms, :incr, 1)
    _ = counter.(scope, key("d", agent_ref), @day_ms, :incr, 1)
    :pass
  end

  # AG-49
  # INV-3
  defp hold(scope, sender, rule_id) do
    event_id = Relay.Id.generate()
    write = fn _status -> Store.hold(event_id, sender.delivery_id, sender.agent_ref, rule_id) end

    case Store.in_scope(scope, write) do
      {:ok, {:held, ceiling_event_id, _count}} -> held(event_id, ceiling_event_id, rule_id)
      {:ok, {:cancelled, _event, _count}} -> cancelled()
      {:ok, {:expired, _event, _count}} -> expired()
      {:ok, {_passed_released_or_gone, _event, _count}} -> :pass
      {:error, _reason} -> unavailable()
    end
  end

  defp held(event_id, ceiling_event_id, rule_id) do
    if ceiling_event_id == event_id, do: Relay.Platform.wake_outbox()
    reason = if rule_id == "agent_ceiling.exceeded", do: :exceeded, else: :counter_unreadable
    :telemetry.execute([:relay, :agents, :ceiling, :held], %{count: 1}, %{reason: reason})
    :held
  end

  defp stopped, do: {:skip, :agent_stopped, "agent_ceiling.stopped"}
  defp cancelled, do: {:skip, :cancelled, "agent_ceiling.cancelled"}
  defp expired, do: {:expire, "agent_ceiling.expired"}
  defp unavailable, do: {:error, {:input_unavailable, :agent_ceiling}}

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Store.in_scope(scope, fun)

  # AG-49
  # TN-21
  # TN-47
  @doc """
  Records the owner's decision inside the caller's scoped transaction and queues the job that applies it. `decision` carries `:agent_ref`, `:ceiling_event_id`, `:decision` (`send_all`, `cancel` or `stop`), `:decision_ref` and `:note`; `digest` is the audit record digest. `{:decided, decision}` for a new decision and `{:exists, decision}` for the same decision again; `{:conflict, decision}` when a different decision stands; `{:step_up_required, nil}` for a release by an actor without a step-up reference; `{:agent_not_found, nil}` and `{:ceiling_event_not_found, nil}`.
  """
  @spec decide_here(Scope.t(), map(), binary(), Actor.t()) :: answer()
  def decide_here(%Scope{} = scope, decision, digest, %Actor{} = actor) do
    id = Relay.Id.generate()

    case Store.decide(Map.put(decision, :id, id), digest, actor) do
      {:decided, ^id, _count} ->
        _job = Oban.insert!(ApplyWorker.job(scope, id))
        {:decided, Store.decision(id)}

      {result, existing, _count} when result in [:exists, :conflict] ->
        {result, Store.decision(existing)}

      {result, _none, _count} ->
        {result, nil}
    end
  end

  # AG-49
  @doc "Applies a decision to the notifications it covers, batch by batch, each batch in a scoped transaction with the send jobs of the deliveries it resumed; returns how many deliveries were resumed, cancelled and expired. Running it again applies only what is left."
  @spec apply_decision(Scope.t(), Relay.Id.t()) :: {:ok, map()} | {:error, term()}
  def apply_decision(%Scope{} = scope, decision_id),
    do: apply_batches(scope, decision_id, %{resumed: 0, cancelled: 0, expired: 0})

  defp apply_batches(scope, decision_id, totals) do
    work = fn _status ->
      rows = Store.apply_batch(decision_id, @batch)
      Enum.each(rows, &queue(scope, &1))
      rows
    end

    case Store.in_scope(scope, work) do
      {:ok, []} -> {:ok, totals}
      {:ok, rows} -> apply_batches(scope, decision_id, Enum.reduce(rows, totals, &tally/2))
      {:error, reason} -> {:error, reason}
    end
  end

  defp queue(scope, {:resumed, id}), do: Oban.insert!(Relay.Delivery.send_job(scope, id))
  defp queue(_scope, _other), do: :ok

  defp tally({:none, _delivery}, totals), do: totals
  defp tally({outcome, _delivery}, totals), do: Map.update!(totals, outcome, &(&1 + 1))

  # AG-49
  # TN-47
  @doc "Lifts a stop decision on an agent inside the caller's scoped transaction, with its audit record; `{:resumed, state}`, `{:unchanged, state}` for an agent that is not stopped, `{:agent_not_found, nil}`."
  @spec resume_here(Relay.Id.t(), String.t(), binary(), Actor.t()) :: answer()
  def resume_here(agent_ref, decision_ref, digest, %Actor{} = actor) do
    case Store.resume(agent_ref, decision_ref, digest, actor) do
      {:agent_not_found, _at} -> {:agent_not_found, nil}
      {result, _at} -> {result, run_state_here(agent_ref)}
    end
  end

  # AG-49
  @doc "The run state of an agent inside the caller's scoped transaction: `:state` (`active` or `stopped`), `:decision_ref` and `:changed_at`; `nil` when the scope has no such agent."
  @spec run_state_here(Relay.Id.t()) :: map() | nil
  def run_state_here(agent_ref) do
    case Store.run_state(agent_ref) do
      nil ->
        nil

      row ->
        %{
          agent_ref: agent_ref,
          state: row["state"] || "active",
          decision_ref: row["decision_ref"],
          changed_at: row["changed_at"] || row["created_at"]
        }
    end
  end

  # AG-49
  # INV-3
  # API-56
  @doc "Lists the notifications of an agent that were held, newest first from a decoded cursor, optionally of one `state` (`held`, `released`, `cancelled` or `expired`); at most `limit + 1` rows come back. `{:ok, nil}` when the scope has no such agent."
  @spec list_holds(Scope.t(), Relay.Id.t(), String.t() | nil, map() | nil, pos_integer()) ::
          {:ok, [map()] | nil} | {:error, term()}
  def list_holds(%Scope{} = scope, agent_ref, state, cursor, limit) do
    Store.in_scope(scope, fn _status ->
      if Store.run_state(agent_ref), do: Store.holds(agent_ref, state, cursor, limit)
    end)
  end
end
