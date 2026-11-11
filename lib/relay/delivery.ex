defmodule Relay.Delivery do
  @moduledoc """
  The delivery ledger, delivery state and reconciliation. Other contexts use only the functions of this module.

  Every function takes the scope and runs in its own scoped transaction (`Relay.Repo.in_scope/3`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  require Logger

  alias Relay.Actor
  alias Relay.Delivery.DeadLetters
  alias Relay.Delivery.Exports
  alias Relay.Delivery.Ledger
  alias Relay.Delivery.Projection
  alias Relay.Delivery.RetryBudget
  alias Relay.Delivery.RetryPolicy
  alias Relay.Delivery.Send
  alias Relay.Delivery.Store
  alias Relay.Delivery.Usage.InvoiceStore
  alias Relay.Scope

  @system %Actor{kind: :system, ref: "relay:dead_letter_auto_replay", on_behalf_of_ref: "relay"}

  @type result(value) :: {:ok, value} | {:error, term()}
  @type tombstone :: :cancelled | :already_sent | :none | :terminal | :not_found
  @type window_move :: %{
          delivery_id: Relay.Id.t(),
          channel: String.t(),
          provider: String.t() | nil,
          window_stage: 1 | 2
        }

  # T-15
  @doc "The job worker that sends a delivery; its arguments are the scope, `notification_id` and `delivery_id`."
  @spec send_worker() :: module()
  def send_worker, do: Send

  # T-15
  # TN-40
  @doc "The send job changeset of a resumed delivery; its arguments are the scope and `delivery_id`."
  @spec send_job(Scope.t(), Relay.Id.t()) :: Ecto.Changeset.t()
  def send_job(%Scope{} = scope, delivery_id) do
    scope
    |> Scope.to_job_args()
    |> Map.put("delivery_id", Relay.Id.to_string(delivery_id))
    |> Send.new()
  end

  # T-26
  # INV-13
  @doc "The send job changeset of a planned retry (`fail_attempt/2`): at the plan's time and priority, carrying the attempt's provider idempotency key unchanged and the `extra` job arguments."
  @spec retry_job(Scope.t(), Relay.Id.t(), map(), map()) :: Ecto.Changeset.t()
  def retry_job(%Scope{} = scope, delivery_id, %{at: at, priority: priority} = plan, extra) do
    scope
    |> Scope.to_job_args()
    |> Map.merge(extra)
    |> Map.merge(%{
      "delivery_id" => Relay.Id.to_string(delivery_id),
      "provider_idempotency_key" => plan.provider_idempotency_key
    })
    |> Send.new(scheduled_at: at, priority: priority)
  end

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

  # OP-3
  # OP-4
  # T-41
  @doc "Appends a ledger entry inside the caller's scoped transaction, so a batch of provider events is written in one transaction; see `Relay.Delivery.Ledger.append/1`."
  @spec ledger_append(Ledger.t()) ::
          {Ledger.result(), Ledger.rank() | nil, non_neg_integer() | nil}
  def ledger_append(%Ledger{} = entry), do: Ledger.append(entry)

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

  # API-58
  # INV-6
  # INV-60
  @doc "Applies the cancellation tombstone that covers a delivery's run, in its own scoped transaction; see `Relay.Delivery.Store.delivery_tombstone_apply/1`."
  @spec apply_tombstone(Scope.t(), Relay.Id.t()) ::
          result({tombstone(), Relay.Id.t() | nil})
  def apply_tombstone(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.delivery_tombstone_apply(delivery_id) end)

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

  # OP-38
  @doc "Records the usage dimensions of a started attempt (`destination_country`, `sms_segments`) for the daily usage records."
  @spec meter_attempt(Scope.t(), Relay.Id.t(), pos_integer(), map()) :: result(atom())
  def meter_attempt(scope, delivery_id, attempt_no, meter) do
    Store.in_scope(scope, fn _status -> Store.attempt_meter(delivery_id, attempt_no, meter) end)
  end

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

  `attrs` holds the `finish_attempt/2` fields (`state` is `:failed` or `:unknown`) and `:channel`, `:provider`, `:condition`, `:message_class`, `:retry_after_ms`, `:expires_at`, `:parameters` (a `Relay.ChannelParameters` snapshot), `:budget` (`:allow` or `:deny`, from `retry_budget/4`), `:rule_id` (of a policy failure), `:uncertain` (`:retry` when the channel's ambiguity decision lets an uncertain attempt be retried, T-28) and `:job`. Returns the finish result, the plan and its outcome.
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
      :rule_id,
      :uncertain
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

  # DS-30
  # DS-52
  @doc "Reads what the engagement of a delivery is classified with; see `Relay.Delivery.Store.engagement/2`."
  @spec engagement(Scope.t(), Relay.Id.t(), DateTime.t()) :: result(map() | nil)
  def engagement(scope, delivery_id, since),
    do: Store.in_scope(scope, fn _status -> Store.engagement(delivery_id, since) end)

  # DS-13
  @doc "Reads what the engagement of a delivery is classified with inside the caller's scoped transaction; see `Relay.Delivery.Store.engagement/2`."
  @spec engagement_in_scope(Relay.Id.t(), DateTime.t()) :: map() | nil
  defdelegate engagement_in_scope(delivery_id, since), to: Store, as: :engagement

  # DS-33
  # E-84
  @doc "Appends an engagement entry inside the caller's scoped transaction and announces the notification's first engagement of `announce` (`seen`, or `clicked` with `link_rel`), or nothing for `nil`; see `Relay.Delivery.Store.engagement_record/3`."
  @spec record_engagement_in_scope(Ledger.t(), String.t() | nil, String.t() | nil) ::
          Ledger.result()
  def record_engagement_in_scope(%Ledger{} = entry, announce, link_rel),
    do: Store.engagement_record(Ledger.params(entry), announce, link_rel)

  # DS-33
  # E-84
  @doc "Appends an engagement entry in its own scoped transaction; see `record_engagement_in_scope/3`."
  @spec record_engagement(Scope.t(), Ledger.t(), String.t() | nil, String.t() | nil) ::
          result(Ledger.result())
  def record_engagement(scope, %Ledger{} = entry, announce, link_rel) do
    Store.in_scope(scope, fn _status ->
      record_engagement_in_scope(entry, announce, link_rel)
    end)
  end

  @doc "Reads the ledger of a delivery."
  @spec ledger(Scope.t(), Relay.Id.t()) :: result([map()])
  def ledger(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.ledger(delivery_id) end)

  # DS-3
  # DS-14
  @doc "The engagement of a delivery from its projection columns; see `Relay.Delivery.Projection.engagement/1`."
  @spec engagement(map()) :: %{String.t() => term()}
  defdelegate engagement(delivery), to: Projection

  # DS-18
  # INV-5
  # INV-9
  @doc """
  Moves up to `limit` due deliveries of a scope through their DLR windows (`Relay.DeliveryWindows.resolve/2` rows), oldest acceptance first: an accepted delivery without a definite event gets `delivery.unknown_pending` once its short window has passed in business time and `delivery.unknown` once its long window has passed, both written by Relay to the ledger. A delivery with a definite event, or locked by another writer, is left alone. Returns the moved deliveries with their channel, provider and new stage; nothing is resent.
  """
  @spec advance_windows(Scope.t(), [map()], pos_integer()) :: result([window_move()])
  def advance_windows(scope, windows, limit) when is_list(windows) and is_integer(limit),
    do: Store.in_scope(scope, fn _status -> Store.windows_advance(windows, limit) end)

  # DS-18
  # TN-13 (4)
  @doc "Lists up to `limit` scopes that have an accepted delivery older than the shortest window, by identifiers only."
  @spec window_scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def window_scopes(limit) when is_integer(limit) and limit > 0,
    do: Store.window_scopes(Relay.DeliveryWindows.floor_ms(), limit)

  # C-88
  # OP-38
  # T-87
  @doc "Writes the usage records of a closed UTC day for every scope; see `Relay.Delivery.Usage.Store.close_day/1`."
  @spec close_usage_day(Date.t()) :: Relay.Delivery.Usage.Store.counts() | {:error, term()}
  defdelegate close_usage_day(day), to: Relay.Delivery.Usage.Store, as: :close_day

  # INV-49
  @doc "The usage rows of a closed day in a scope, before they are written; see `Relay.Delivery.Usage.Store.rows/1`."
  @spec usage_rows(Scope.t(), Date.t()) :: result([map()])
  def usage_rows(scope, day),
    do: Store.in_scope(scope, fn _status -> Relay.Delivery.Usage.Store.rows(day) end)

  # OP-38
  # OP-42
  @doc "Records a provider invoice inside the caller's scoped transaction of `scope` and reconciles a new one at once with the usage records of its period; see `Relay.Delivery.Usage.InvoiceStore`."
  @spec record_invoice(Scope.t(), map(), <<_::256>>, Actor.t()) ::
          {:recorded | :exists | :conflict, Relay.Id.t()}
  def record_invoice(%Scope{} = scope, attrs, digest, %Actor{} = actor) do
    case InvoiceStore.record(attrs, digest, actor) do
      {:recorded, id} ->
        if InvoiceStore.check(id) == {:changed, :drift}, do: InvoiceStore.alarm(scope, [id])
        {:recorded, id}

      other ->
        other
    end
  end

  # OP-42
  @doc "Reconciles a provider invoice again inside the caller's scoped transaction."
  @spec check_invoice(Relay.Id.t()) ::
          {:changed | :unchanged | :not_found, :matched | :drift | nil}
  defdelegate check_invoice(id), to: InvoiceStore, as: :check

  @doc "Reads a provider invoice inside the caller's scoped transaction, or `nil`."
  @spec invoice(Relay.Id.t()) :: map() | nil
  defdelegate invoice(id), to: InvoiceStore, as: :get

  @doc "Reads a provider invoice in its own scoped transaction, or `nil`."
  @spec get_invoice(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def get_invoice(scope, id), do: Store.in_scope(scope, fn _status -> InvoiceStore.get(id) end)

  # DS-35
  # OP-39
  @doc "Recomputes the report rollups of `days` for every tenant scope; see `Relay.Delivery.Reports.Store.recompute_all/1`."
  @spec recompute_reports([Date.t()]) :: non_neg_integer()
  defdelegate recompute_reports(days), to: Relay.Delivery.Reports.Store, as: :recompute_all

  # DS-35
  @doc "Recomputes the report rollups of one UTC day in its own scoped transaction."
  @spec recompute_report_day(Scope.t(), Date.t()) ::
          result(%{deliveries: non_neg_integer(), skips: non_neg_integer()})
  def recompute_report_day(scope, day),
    do: Store.in_scope(scope, fn _status -> Relay.Delivery.Reports.Store.recompute(day) end)

  # DS-35
  # TN-18
  @doc "Reads a report (`:deliveries`, `:skips` or `:costs`) of the UTC days `from` to `to` (exclusive) on the report pool; see `Relay.Delivery.Reports.Store.read/4`."
  @spec report(Scope.t(), :deliveries | :skips | :costs, Date.t(), Date.t()) :: result([map()])
  defdelegate report(scope, kind, from, to), to: Relay.Delivery.Reports.Store, as: :read

  # DS-37
  @doc "Records an export request inside the caller's scoped transaction, audits it and queues its job in the same transaction; see `Relay.Delivery.Exports.Store`."
  @spec request_export(Scope.t(), map(), <<_::256>>, Actor.t()) :: :requested
  def request_export(%Scope{} = scope, attrs, digest, %Actor{} = actor) do
    result = Exports.Store.request(attrs, digest, actor)
    args = scope |> Scope.to_job_args() |> Map.put("export_id", Relay.Id.to_string(attrs.id))
    Store.insert_job!(Relay.Delivery.ExportJob.new(args), result)
  end

  @doc "Reads an export without its content inside the caller's scoped transaction, or `nil`."
  @spec export(Relay.Id.t()) :: map() | nil
  defdelegate export(id), to: Exports.Store, as: :get

  @doc "Reads an export without its content in its own scoped transaction, or `nil`."
  @spec get_export(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def get_export(scope, id), do: Store.in_scope(scope, fn _status -> Exports.Store.get(id) end)

  # API-56
  @doc "Lists exports newest first from a decoded cursor in their own scoped transaction; at most `limit + 1` rows come back."
  @spec list_exports(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list_exports(scope, cursor, limit),
    do: Store.in_scope(scope, fn _status -> Exports.Store.page(cursor, limit) end)

  # DS-37
  @doc "Writes the CSV of a pending export; see `Relay.Delivery.Exports.Store.run/2`."
  @spec run_export(Scope.t(), Relay.Id.t()) ::
          {:ok, :completed | :failed | :not_pending | :not_found} | {:error, term()}
  defdelegate run_export(scope, id), to: Exports.Store, as: :run

  # DS-37
  @doc "Fails a pending export as `unavailable` in its own scoped transaction."
  @spec fail_export(Scope.t(), Relay.Id.t()) :: result(:failed | :not_pending | :not_found)
  def fail_export(scope, id),
    do: Store.in_scope(scope, fn _status -> Exports.Store.fail(id, "unavailable") end)

  # DS-37
  @doc "Downloads a ready export in its own scoped transaction and audits the download: `{:ready, export, content}`, or `:expired`, `:not_ready` or `:not_found`."
  @spec download_export(Scope.t(), Relay.Id.t(), <<_::256>>, Actor.t()) ::
          result({:ready, map(), binary()} | :expired | :not_ready | :not_found)
  def download_export(scope, id, digest, %Actor{} = actor) do
    Store.in_scope(scope, fn _status ->
      case Exports.Store.download(id, digest, actor) do
        :ready -> {:ready, Exports.Store.get(id), Exports.Store.content(id)}
        other -> other
      end
    end)
  end

  # DS-37
  @doc "Signs the download link token of an export; see `Relay.Delivery.Exports.Link.sign/3`."
  @spec export_link(Scope.t(), Relay.Id.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  defdelegate export_link(scope, id, expires_at), to: Exports.Link, as: :sign

  # DS-37
  @doc "Verifies a download link token now; see `Relay.Delivery.Exports.Link.verify/2`."
  @spec verify_export_link(String.t()) ::
          {:ok, Exports.Link.claims()} | {:error, :invalid | :expired | Relay.Error.t()}
  def verify_export_link(token), do: Exports.Link.verify(token, Relay.Clock.utc_now())

  # API-56
  @doc "Lists provider invoices newest first from a decoded cursor in their own scoped transaction; at most `limit + 1` rows come back."
  @spec list_invoices(Scope.t(), map() | nil, pos_integer()) :: result([map()])
  def list_invoices(scope, cursor, limit),
    do: Store.in_scope(scope, fn _status -> InvoiceStore.page(cursor, limit) end)
end
