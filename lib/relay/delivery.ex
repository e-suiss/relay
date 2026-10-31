defmodule Relay.Delivery do
  @moduledoc """
  The delivery ledger, delivery state and reconciliation. Other contexts use only the functions of this module.

  Every function takes the scope and runs in its own scoped transaction (`Relay.Repo.in_scope/3`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  require Logger

  alias Relay.Actor
  alias Relay.Delivery.DeadLetters
  alias Relay.Delivery.Ledger
  alias Relay.Delivery.RetryBudget
  alias Relay.Delivery.RetryPolicy
  alias Relay.Delivery.Store
  alias Relay.Scope

  @system %Actor{kind: :system, ref: "relay:dead_letter_auto_replay", on_behalf_of_ref: "relay"}

  @type result(value) :: {:ok, value} | {:error, term()}

  # T-15
  @doc "The job worker that sends a delivery; its arguments are the scope, `notification_id` and `delivery_id`."
  @spec send_worker() :: module()
  def send_worker, do: Relay.Delivery.Send

  # C-32
  @doc "Builds a ledger entry; see `Relay.Delivery.Ledger.new/1`."
  @spec ledger_entry(map() | keyword()) :: {:ok, Ledger.t()} | {:error, Relay.Error.t()}
  defdelegate ledger_entry(attrs), to: Ledger, as: :new

  # OP-3
  # OP-4
  @doc "Appends a ledger entry; see `Relay.Delivery.Ledger.append/1`."
  @spec append_ledger(Scope.t(), Ledger.t()) ::
          result({Ledger.result(), Ledger.rank() | nil, non_neg_integer() | nil})
  def append_ledger(scope, %Ledger{} = entry),
    do: Store.in_scope(scope, fn _status -> Ledger.append(entry) end)

  @doc "Cancels a delivery."
  @spec cancel_delivery(Scope.t(), Relay.Id.t(), String.t(), binary(), Actor.t()) ::
          result(atom())
  def cancel_delivery(scope, delivery_id, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.delivery_cancel(delivery_id, rule_id, digest, actor)
    end)
  end

  @doc "Cancels a notification and its pending deliveries."
  @spec cancel_notification(Scope.t(), Relay.Id.t(), String.t(), binary(), Actor.t()) ::
          result({atom(), non_neg_integer() | nil})
  def cancel_notification(scope, notification_id, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.notification_cancel(notification_id, rule_id, digest, actor)
    end)
  end

  # C-31
  @doc "Opens the next attempt of a delivery."
  @spec open_attempt(Scope.t(), map()) :: result({atom(), non_neg_integer() | nil})
  def open_attempt(scope, attrs),
    do: Store.in_scope(scope, fn _status -> Store.attempt_open(attrs) end)

  # INV-55
  @doc "Marks an attempt started in its own transaction, before the provider call."
  @spec start_attempt(Scope.t(), Relay.Id.t(), pos_integer()) :: result(atom())
  def start_attempt(scope, delivery_id, attempt_no),
    do: Store.in_scope(scope, fn _status -> Store.attempt_start(delivery_id, attempt_no) end)

  # T-29
  @doc "Finishes an attempt; a succeeded attempt of a replay marks its dead letter replayed."
  @spec finish_attempt(Scope.t(), map()) :: result({atom(), atom() | nil})
  def finish_attempt(scope, attrs) do
    Store.in_scope(scope, fn _status ->
      result = Store.attempt_finish(attrs)

      with {:applied, _} <- result,
           :succeeded <- attrs.state,
           id when id != nil <- Store.replaying_dead_letter(attrs.delivery_id),
           do: Store.dead_letter_replay_finish(id, true)

      result
    end)
  end

  # T-26
  # T-28
  # T-29
  # CH-9
  # CH-12
  # CH-70
  # INV-13
  @doc """
  Finishes a failed or uncertain attempt and carries out its retry plan in the same transaction (`Relay.Delivery.RetryPolicy.next/1`, with the transaction's database clock). A retry is a new job, never a retry inside the adapter or the HTTP client: `:job` builds its changeset from `%{at: at, priority: priority, attempt_no: next, provider_idempotency_key: key}`, where `key` is the failed attempt's key that the next attempt opens with unchanged (INV-13), and it is inserted in this transaction. A dead letter, an expiry or a policy failure closes the delivery; a failed replay marks its dead letter replayed before the new one is recorded.

  `attrs` holds the `finish_attempt/2` fields (`state` is `:failed` or `:unknown`) and `:channel`, `:provider`, `:condition`, `:message_class`, `:retry_after_ms`, `:expires_at`, `:parameters` (a `Relay.ChannelParameters` snapshot), `:budget` (`:allow` or `:deny`, from `retry_budget/4`), `:rule_id` (of a policy failure) and `:job`. Returns the finish result, the plan and its outcome.
  """
  @spec fail_attempt(Scope.t(), map()) :: result({atom(), RetryPolicy.plan() | nil, term()})
  def fail_attempt(%Scope{} = scope, %{state: state} = attrs) when state in [:failed, :unknown] do
    Store.in_scope(scope, fn _status ->
      case Store.attempt_finish(attrs) do
        {:applied, _projection} ->
          plan = RetryPolicy.next(policy_input(scope, attrs, Store.now()))
          {:applied, plan, apply_plan(plan, attrs)}

        {result, _projection} ->
          {result, nil, nil}
      end
    end)
  end

  defp policy_input(scope, attrs, now) do
    attrs
    |> Map.take([
      :state,
      :failure_class,
      :condition,
      :channel,
      :provider,
      :message_class,
      :retry_after_ms,
      :expires_at,
      :parameters,
      :budget,
      :rule_id
    ])
    |> Map.merge(%{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      delivery_id: attrs.delivery_id,
      attempt_no: attrs.attempt_no,
      now: now
    })
  end

  defp apply_plan({:retry, at, priority, next}, attrs) do
    key = Store.attempt_key(attrs.delivery_id, attrs.attempt_no)

    attrs.job.(%{at: at, priority: priority, attempt_no: next, provider_idempotency_key: key})
    |> insert!(:scheduled)
  end

  defp apply_plan({:dead_letter, class, rule_id}, attrs) do
    if rule_id == "channel_parameters.missing", do: missing_parameters(attrs)
    finish_replay_failed(attrs.delivery_id)

    Store.dead_letter_record(%{
      id: Relay.Id.generate(),
      delivery_id: attrs.delivery_id,
      dlq_class: class,
      failure_class: attrs.failure_class,
      raw_code: Map.get(attrs, :raw_code),
      invalidates_target: DeadLetters.invalidates_target?(attrs.failure_class),
      entry_rule_id: rule_id,
      channel_parameters_version_id: attrs.parameters.version_id
    })
  end

  defp apply_plan({:expire, rule_id}, attrs) do
    finish_replay_failed(attrs.delivery_id)
    Store.delivery_expire(attrs.delivery_id, rule_id)
  end

  defp apply_plan({:fail, rule_id}, attrs) do
    finish_replay_failed(attrs.delivery_id)

    {:ok, entry} =
      Ledger.new(
        id: Relay.Id.generate(),
        delivery_id: attrs.delivery_id,
        attempt_no: attrs.attempt_no,
        actor: :relay,
        event_type: "attempt.failed",
        occurred_at: Relay.Clock.utc_now(),
        raw_code: Map.get(attrs, :raw_code),
        provider: Map.get(attrs, :provider),
        failure_kind: :failed,
        failure_class: to_string(attrs.failure_class),
        failure_rule_id: rule_id
      )

    Ledger.append(entry)
  end

  defp apply_plan({:no_retry, _rule_id}, _attrs), do: :none

  defp finish_replay_failed(delivery_id) do
    case Store.replaying_dead_letter(delivery_id) do
      nil -> :ok
      id -> Store.dead_letter_replay_finish(id, false)
    end
  end

  # CH-70
  defp missing_parameters(attrs) do
    meta = %{channel: to_string(attrs.channel), failure_class: to_string(attrs.failure_class)}
    :telemetry.execute([:relay, :channel_parameters, :missing], %{count: 1}, meta)

    Logger.error("no channel_parameters backoff row; the delivery goes to the dead letters",
      channel: meta.channel,
      failure_class: meta.failure_class
    )
  end

  # T-27
  @doc "Counts an attempt start in the retry budget of its channel and provider account, in its own transaction under the account owner's scope."
  @spec count_attempt(
          Scope.t(),
          Relay.ChannelParameters.t(),
          String.t() | atom(),
          Relay.Id.t() | nil,
          pos_integer()
        ) :: result(:ok)
  def count_attempt(owner_scope, parameters, channel, account_id, attempt_no) do
    {:ok, row, _version} = Relay.ChannelParameters.retry_budget(parameters, channel)

    Store.in_scope(owner_scope, fn _status ->
      RetryBudget.count(channel, account_id, attempt_no, row["window_ms"])
    end)
  end

  # T-27
  @doc "Decides whether one more retry fits the retry budget of a channel and provider account, in its own transaction under the account owner's scope."
  @spec retry_budget(
          Scope.t(),
          Relay.ChannelParameters.t(),
          String.t() | atom(),
          Relay.Id.t() | nil
        ) :: result(RetryBudget.decision())
  def retry_budget(owner_scope, parameters, channel, account_id) do
    {:ok, row, _version} = Relay.ChannelParameters.retry_budget(parameters, channel)
    Store.in_scope(owner_scope, fn _status -> RetryBudget.check(channel, account_id, row) end)
  end

  # C-88
  @doc "Appends a usage record for a closed UTC day."
  @spec record_usage(Scope.t(), map()) :: result(atom())
  def record_usage(scope, attrs),
    do: Store.in_scope(scope, fn _status -> Store.usage_record_append(attrs) end)

  # C-2
  @doc "Rebuilds a delivery projection from the ledger and returns the differences."
  @spec rebuild_projection(Scope.t(), Relay.Id.t()) :: result([{String.t(), term(), term()}])
  def rebuild_projection(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.projection_rebuild(delivery_id) end)

  @doc "Reads a notification; another tenant's or environment's notification is not found (TN-15)."
  @spec notification(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def notification(scope, id), do: Store.in_scope(scope, fn _status -> Store.notification(id) end)

  @doc "Reads a delivery; another tenant's or environment's delivery is not found (TN-15)."
  @spec delivery(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def delivery(scope, id), do: Store.in_scope(scope, fn _status -> Store.delivery(id) end)

  # OP-3
  # OP-42
  @doc """
  Rebuilds the projections of up to `limit` deliveries of a scope whose identifiers follow `after_id` (`nil` starts at the first) and compares each with its stored projection, in one read-only transaction. Returns the checked identifiers in order and the deliveries whose projection differs, with the differing columns.
  """
  @spec check_projections(Scope.t(), Relay.Id.t() | nil, pos_integer()) ::
          result(%{
            checked: [Relay.Id.t()],
            differing: [{Relay.Id.t(), [{String.t(), term(), term()}]}]
          })
  def check_projections(scope, after_id, limit) when is_integer(limit) and limit > 0 do
    Store.in_scope(scope, fn _status ->
      ids = Store.delivery_ids_after(after_id, limit)

      differing =
        for id <- ids, diff = Store.projection_rebuild(id), diff != [], do: {id, diff}

      %{checked: ids, differing: differing}
    end)
  end

  # T-15 (5)
  # TN-40
  @doc """
  Reads the gate of a delivery, the first step of its job: `:sendable`, `:cancelled`, `:paused`, `:expired` (past `expires_at` and not yet closed; close it with `expire/3`), `:terminal`, `:deferred` or `:not_found`, with the channel, message class, subtenant, provider account, notification, `expires_at` and attempt count.
  """
  @spec gate(Scope.t(), Relay.Id.t()) :: result(map())
  def gate(scope, delivery_id) do
    Store.in_scope(scope, fn _status ->
      row = Store.delivery_gate(delivery_id)

      %{
        result: row["result"],
        channel: row["channel"],
        message_class: row["message_class"],
        subtenant_id: row["subtenant_id"],
        provider_account_id: row["provider_account_id"],
        notification_id: row["notification_id"],
        expires_at: row["expires_at"],
        attempt_count: row["attempt_count"]
      }
    end)
  end

  # TN-40
  # C-65
  @doc "Pauses a delivery for a kill switch: it is kept, not failed and never retried until it is resumed."
  @spec pause(Scope.t(), Relay.Id.t(), String.t(), Relay.Id.t() | nil) :: result(atom())
  def pause(scope, delivery_id, rule_id, kill_switch_id) do
    Store.in_scope(scope, fn _status ->
      Store.delivery_pause(delivery_id, rule_id, kill_switch_id)
    end)
  end

  # TN-40
  @doc "Resumes a paused delivery after the policy lattice decided to send it; `job`, if given, is inserted in the same transaction when the delivery resumes."
  @spec resume(Scope.t(), Relay.Id.t(), String.t(), String.t(), Ecto.Changeset.t() | nil) ::
          result(atom())
  def resume(scope, delivery_id, decision_ref, rule_id, job \\ nil) do
    Store.in_scope(scope, fn _status ->
      case Store.delivery_resume(delivery_id, decision_ref, rule_id) do
        :resumed when job != nil -> insert!(job, :resumed)
        result -> result
      end
    end)
  end

  # T-34 (3)
  @doc "Records that load shedding holds a delivery until `until`."
  @spec hold(Scope.t(), Relay.Id.t(), String.t(), DateTime.t()) :: result(atom())
  def hold(scope, delivery_id, rule_id, until),
    do: Store.in_scope(scope, fn _status -> Store.delivery_hold(delivery_id, rule_id, until) end)

  # T-26
  # TN-40
  @doc "Closes a delivery past its useful life as `expired`."
  @spec expire(Scope.t(), Relay.Id.t(), String.t()) :: result(atom())
  def expire(scope, delivery_id, rule_id),
    do: Store.in_scope(scope, fn _status -> Store.delivery_expire(delivery_id, rule_id) end)

  # T-29
  @doc "Records a dead letter for a failed delivery outside a retry plan, such as a `quality_alarm`."
  @spec record_dead_letter(Scope.t(), map()) :: result({atom(), Relay.Id.t() | nil})
  def record_dead_letter(scope, attrs) do
    attrs =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          invalidates_target: DeadLetters.invalidates_target?(attrs.failure_class)
        },
        attrs
      )

    Store.in_scope(scope, fn _status -> Store.dead_letter_record(attrs) end)
  end

  # T-29
  # INV-3
  @doc """
  Replays a dead letter. The replay opens a new attempt whose provider idempotency key is derived from the original key and the dead letter (`Relay.Delivery.DeadLetters.replay_key/2`); `:job` builds the changeset of the replay job from `%{attempt_no: n, dead_letter_id: id, delivery_id: d}` and it is inserted in the same transaction. Options: `:job` (required), `:actor` (defaults to the system actor of the automatic replay, which is not audited), `:digest` (the audit record digest of an operator's replay), `:approval_ref` (required for `quality_alarm`) and `:cause_fixed_ref` (required for `permanent`).
  """
  @spec replay_dead_letter(Scope.t(), Relay.Id.t(), keyword()) ::
          result({atom(), non_neg_integer() | nil})
  def replay_dead_letter(scope, dead_letter_id, opts) do
    job = Keyword.fetch!(opts, :job)
    actor = Keyword.get(opts, :actor, @system)

    Store.in_scope(scope, fn _status ->
      case Store.dead_letter(dead_letter_id) do
        nil -> {:not_found, nil}
        letter -> replay(letter, dead_letter_id, job, actor, opts)
      end
    end)
  end

  defp replay(letter, dead_letter_id, job, actor, opts) do
    attrs = %{
      dead_letter_id: dead_letter_id,
      attempt_id: Relay.Id.generate(),
      replay_idempotency_key:
        DeadLetters.replay_key(letter["provider_idempotency_key"], dead_letter_id),
      approval_ref: Keyword.get(opts, :approval_ref),
      cause_fixed_ref: Keyword.get(opts, :cause_fixed_ref),
      digest: Keyword.get(opts, :digest)
    }

    case Store.dead_letter_replay(attrs, actor) do
      {:replay_opened, n} ->
        changeset =
          job.(%{
            attempt_no: n,
            dead_letter_id: dead_letter_id,
            delivery_id: letter["delivery_id"]
          })

        insert!(changeset, {:replay_opened, n})

      other ->
        other
    end
  end

  # T-29
  @doc "Marks a replaying dead letter replayed once its replay attempt finished."
  @spec finish_replay(Scope.t(), Relay.Id.t(), boolean()) :: result(atom())
  def finish_replay(scope, dead_letter_id, succeeded?) do
    Store.in_scope(scope, fn _status ->
      Store.dead_letter_replay_finish(dead_letter_id, succeeded?)
    end)
  end

  # T-29
  @doc "Closes an open dead letter; an `:operator` close is audited and needs the record digest."
  @spec close_dead_letter(Scope.t(), Relay.Id.t(), atom(), binary() | nil, Actor.t()) ::
          result(atom())
  def close_dead_letter(scope, dead_letter_id, reason, digest, %Actor{} = actor) do
    Store.in_scope(scope, fn _status ->
      Store.dead_letter_close(dead_letter_id, reason, digest, actor)
    end)
  end

  # T-29
  @doc "Lists dead letters in identifier order. Options: `:states`, `:classes`, `:channel`, `:after_id` and `:limit` (default 100, at most 1000)."
  @spec list_dead_letters(Scope.t(), keyword()) :: result([map()])
  def list_dead_letters(scope, opts \\ []) do
    Store.in_scope(scope, fn _status ->
      Store.dead_letter_list(
        texts(Keyword.get(opts, :states)),
        texts(Keyword.get(opts, :classes)),
        text(Keyword.get(opts, :channel)),
        Keyword.get(opts, :after_id),
        Keyword.get(opts, :limit, 100)
      )
    end)
  end

  # T-29 (6)
  @doc "Lists the open `exhausted` dead letters of a provider recorded since `since` in a scope."
  @spec auto_replay_candidates(Scope.t(), String.t(), DateTime.t(), pos_integer()) ::
          result([Relay.Id.t()])
  def auto_replay_candidates(scope, provider, since, limit) do
    Store.in_scope(scope, fn _status ->
      Store.dead_letter_auto_replay_candidates(provider, since, limit)
    end)
  end

  # T-29 (6)
  @doc "Attaches the handler that queues the automatic replay when a provider's circuit breaker closes."
  @spec attach_auto_replay() :: :ok | {:error, :already_exists}
  defdelegate attach_auto_replay(), to: DeadLetters.AutoReplay, as: :attach

  defp insert!(changeset, result), do: Store.insert_job!(changeset, result)

  defp texts(nil), do: nil
  defp texts(values), do: Enum.map(values, &to_string/1)

  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  @doc "Reads the ledger of a delivery."
  @spec ledger(Scope.t(), Relay.Id.t()) :: result([map()])
  def ledger(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.ledger(delivery_id) end)
end
