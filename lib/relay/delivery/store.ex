defmodule Relay.Delivery.Store do
  @moduledoc """
  Data access for deliveries after acceptance: cancellation, the delivery gate, pausing, holding and expiry, attempts, the ledger, dead letters, usage records and projection checks. Every function runs inside `Relay.Repo.in_scope/3`; writes call the `relay_fn` functions.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @ledger_results [
    :applied,
    :duplicate_ignored,
    :stale_ignored,
    :conflict_flagged,
    :delivery_not_found,
    :attempt_not_found,
    :rejected_future_timestamp
  ]

  # TN-40
  @doc "Cancels a delivery that is not yet terminal, writing `delivery.cancelled`."
  @spec delivery_cancel(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          :cancelled | :already_terminal | :not_found
  def delivery_cancel(delivery_id, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.delivery_cancel",
        [delivery_id, rule_id, digest] ++ Actor.params(actor)
      )

    Repo.code!(row["delivery_cancel"], [:cancelled, :already_terminal, :not_found])
  end

  @doc "Cancels a notification and its pending deliveries."
  @spec notification_cancel(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:cancelled | :already_closed | :not_found, non_neg_integer() | nil}
  def notification_cancel(notification_id, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.notification_cancel",
        [notification_id, rule_id, digest] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [:cancelled, :already_closed, :not_found]),
     row["cancelled_deliveries"]}
  end

  # C-31
  @doc "Opens the next attempt of a sendable delivery; only one attempt is active at a time."
  @spec attempt_open(map()) ::
          {:opened
           | :delivery_not_found
           | :delivery_not_sendable
           | :delivery_paused
           | :attempt_active
           | :tenant_inactive, non_neg_integer() | nil}
  def attempt_open(attrs) do
    [row] =
      Repo.call!("relay_fn.attempt_open", [
        attrs.id,
        attrs.delivery_id,
        Map.get(attrs, :provider),
        Map.get(attrs, :provider_account_id),
        Map.get(attrs, :provider_idempotency_key)
      ])

    {Repo.code!(row["result"], [
       :opened,
       :delivery_not_found,
       :delivery_not_sendable,
       :delivery_paused,
       :attempt_active,
       :tenant_inactive
     ]), row["attempt_no"]}
  end

  # T-15 (5)
  # TN-40
  @doc "Reads the gate of a delivery: whether its job may send, and what the job needs to decide."
  @spec delivery_gate(Relay.Id.t()) :: map()
  def delivery_gate(delivery_id) do
    [row] = Repo.call!("relay_fn.delivery_gate", [delivery_id])

    Map.put(
      row,
      "result",
      Repo.code!(row["result"], [
        :sendable,
        :cancelled,
        :paused,
        :expired,
        :terminal,
        :deferred,
        :not_found
      ])
    )
  end

  # TN-40
  @doc "Marks a delivery paused by a kill switch; a pause is not a cancellation."
  @spec delivery_pause(Relay.Id.t(), String.t(), Relay.Id.t() | nil) ::
          :paused | :already_paused | :already_terminal | :not_found
  def delivery_pause(delivery_id, rule_id, kill_switch_id) do
    [row] = Repo.call!("relay_fn.delivery_pause", [delivery_id, rule_id, kill_switch_id])
    Repo.code!(row["delivery_pause"], [:paused, :already_paused, :already_terminal, :not_found])
  end

  # TN-40
  @doc "Lifts the pause of a delivery after the policy lattice decided to send it."
  @spec delivery_resume(Relay.Id.t(), String.t(), String.t()) ::
          :resumed | :not_paused | :already_terminal | :not_found
  def delivery_resume(delivery_id, decision_ref, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_resume", [delivery_id, decision_ref, rule_id])
    Repo.code!(row["delivery_resume"], [:resumed, :not_paused, :already_terminal, :not_found])
  end

  # T-34 (3)
  @doc "Records that load shedding holds a delivery until `until`; only a ledger event."
  @spec delivery_hold(Relay.Id.t(), String.t(), DateTime.t()) ::
          :held | :already_terminal | :not_found
  def delivery_hold(delivery_id, rule_id, until) do
    [row] = Repo.call!("relay_fn.delivery_hold", [delivery_id, rule_id, until])
    Repo.code!(row["delivery_hold"], [:held, :already_terminal, :not_found])
  end

  # T-26
  # TN-40
  @doc "Closes a delivery whose useful life is over as `expired`."
  @spec delivery_expire(Relay.Id.t(), String.t()) :: :expired | :already_terminal | :not_found
  def delivery_expire(delivery_id, rule_id) do
    [row] = Repo.call!("relay_fn.delivery_expire", [delivery_id, rule_id])
    Repo.code!(row["delivery_expire"], [:expired, :already_terminal, :not_found])
  end

  # T-11
  @doc "Reads the database clock of the current transaction."
  @spec now() :: DateTime.t()
  def now do
    %Postgrex.Result{rows: [[now]]} = Repo.scoped_query!("SELECT now()", [])
    now
  end

  # T-29
  @doc "Records a dead letter for a failed delivery; a delivery has at most one open dead letter."
  @spec dead_letter_record(map()) ::
          {:recorded | :already_open | :delivery_not_found | :delivery_terminal,
           Relay.Id.t() | nil}
  def dead_letter_record(attrs) do
    [row] =
      Repo.call!("relay_fn.dead_letter_record", [
        attrs.id,
        attrs.delivery_id,
        Atom.to_string(attrs.dlq_class),
        to_text(attrs.failure_class),
        Map.get(attrs, :raw_code),
        attrs.invalidates_target,
        attrs.entry_rule_id,
        Map.get(attrs, :channel_parameters_version_id)
      ])

    {Repo.code!(row["result"], [:recorded, :already_open, :delivery_not_found, :delivery_terminal]),
     row["dead_letter_id"]}
  end

  # T-29
  @doc "Replays a dead letter: opens a new attempt with the derived key, or says why it may not."
  @spec dead_letter_replay(map(), Actor.t()) ::
          {:replay_opened
           | :not_replayable
           | :approval_required
           | :cause_fix_required
           | :depth_exceeded
           | :expired
           | :not_open
           | :not_found
           | :tenant_inactive, non_neg_integer() | nil}
  def dead_letter_replay(attrs, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.dead_letter_replay",
        [
          attrs.dead_letter_id,
          attrs.attempt_id,
          attrs.replay_idempotency_key,
          Map.get(attrs, :approval_ref),
          Map.get(attrs, :cause_fixed_ref),
          Map.get(attrs, :digest)
        ] ++ Actor.params(actor)
      )

    {Repo.code!(row["result"], [
       :replay_opened,
       :not_replayable,
       :approval_required,
       :cause_fix_required,
       :depth_exceeded,
       :expired,
       :not_open,
       :not_found,
       :tenant_inactive
     ]), row["attempt_no"]}
  end

  # T-29
  @doc "Closes an open dead letter; an operator's close is audited."
  @spec dead_letter_close(Relay.Id.t(), atom(), binary() | nil, Actor.t()) ::
          :closed | :not_open | :not_found
  def dead_letter_close(id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.dead_letter_close",
        [id, Atom.to_string(reason), digest] ++ Actor.params(actor)
      )

    Repo.code!(row["dead_letter_close"], [:closed, :not_open, :not_found])
  end

  # T-29
  @doc "Marks a replaying dead letter replayed once its replay attempt has finished."
  @spec dead_letter_replay_finish(Relay.Id.t(), boolean()) ::
          :replayed | :not_replaying | :not_found
  def dead_letter_replay_finish(id, succeeded?) when is_boolean(succeeded?) do
    [row] = Repo.call!("relay_fn.dead_letter_replay_finish", [id, succeeded?])
    Repo.code!(row["dead_letter_replay_finish"], [:replayed, :not_replaying, :not_found])
  end

  # T-29
  @doc "Lists dead letters of the established scope in identifier order."
  @spec dead_letter_list(
          [String.t()] | nil,
          [String.t()] | nil,
          String.t() | nil,
          Relay.Id.t() | nil,
          pos_integer()
        ) :: [map()]
  def dead_letter_list(states, classes, channel, after_id, limit) do
    Repo.call!("relay_fn.dead_letter_list", [states, classes, channel, after_id, limit])
  end

  # T-29 (6)
  @doc "Lists the open `exhausted` dead letters of a provider recorded since `since`."
  @spec dead_letter_auto_replay_candidates(String.t(), DateTime.t(), pos_integer()) ::
          [Relay.Id.t()]
  def dead_letter_auto_replay_candidates(provider, since, limit) do
    for row <-
          Repo.call!("relay_fn.dead_letter_auto_replay_candidates", [provider, since, limit]),
        do: row["dead_letter_id"]
  end

  # T-29 (6)
  @doc "Lists the tenant scopes holding open `exhausted` dead letters of a provider recorded since `since`, through the maintenance escape hatch."
  @spec dead_letter_auto_replay_scopes(String.t(), DateTime.t(), pos_integer()) :: [map()]
  def dead_letter_auto_replay_scopes(provider, since, limit) do
    Repo.call_unscoped!(
      :dead_letter_scope_discovery,
      "relay_ops.dead_letter_auto_replay_scopes",
      [provider, since, limit]
    )
  end

  # T-27
  @doc "Applies `op` to a retry budget counter and returns its sliding window estimate."
  @spec retry_counter(String.t(), pos_integer(), String.t(), non_neg_integer()) :: number()
  def retry_counter(key, window_ms, op, by) do
    [%{"estimate" => estimate}] = Repo.call!("relay_fn.rl_counter", [key, window_ms, op, by])
    estimate
  end

  # T-26
  @doc "Queues a job inside the current transaction and returns `result`; rolls the transaction back when the job is not queued."
  @spec insert_job!(Ecto.Changeset.t(), term()) :: term()
  def insert_job!(changeset, result) do
    case Oban.insert(changeset) do
      {:ok, _job} -> result
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # T-29 (5)
  @doc "Reads a dead letter with the provider idempotency key of its delivery's first attempt."
  @spec dead_letter(Relay.Id.t()) :: map() | nil
  def dead_letter(id) do
    one(
      """
      SELECT l.tenant_id, l.environment, l.id, l.created_at, l.delivery_id, l.channel, l.provider,
        l.dlq_class, l.failure_class, l.state, l.replay_depth, l.entry_rule_id,
        (SELECT a.provider_idempotency_key FROM relay.delivery_attempts a
          WHERE a.tenant_id = l.tenant_id AND a.environment = l.environment
            AND a.delivery_id = l.delivery_id
          ORDER BY a.attempt_no LIMIT 1) AS provider_idempotency_key
      FROM relay.dead_letters l WHERE l.id = $1
      """,
      [id]
    )
  end

  # INV-13
  @doc "Returns the provider idempotency key of an attempt."
  @spec attempt_key(Relay.Id.t(), pos_integer()) :: String.t() | nil
  def attempt_key(delivery_id, attempt_no) do
    case one(
           "SELECT tenant_id, environment, provider_idempotency_key FROM relay.delivery_attempts WHERE delivery_id = $1 AND attempt_no = $2",
           [delivery_id, attempt_no]
         ) do
      nil -> nil
      row -> row["provider_idempotency_key"]
    end
  end

  # T-29
  @doc "Returns the dead letter of a delivery that is being replayed, if any."
  @spec replaying_dead_letter(Relay.Id.t()) :: Relay.Id.t() | nil
  def replaying_dead_letter(delivery_id) do
    case one(
           "SELECT tenant_id, environment, id FROM relay.dead_letters WHERE delivery_id = $1 AND state = 'replaying' LIMIT 1",
           [delivery_id]
         ) do
      nil -> nil
      row -> row["id"]
    end
  end

  # INV-55
  # OP-6 (3)
  @doc "Marks an attempt started; commit it before calling the provider."
  @spec attempt_start(Relay.Id.t(), pos_integer()) :: :started | :not_pending | :not_found
  def attempt_start(delivery_id, attempt_no) do
    [row] = Repo.call!("relay_fn.attempt_start", [delivery_id, attempt_no])
    Repo.code!(row["attempt_start"], [:started, :not_pending, :not_found])
  end

  # C-31
  @doc "Finishes an attempt; a terminal attempt is never overwritten."
  @spec attempt_finish(map()) ::
          {:applied | :duplicate_ignored | :already_terminal | :not_found, atom() | nil}
  def attempt_finish(attrs) do
    [row] =
      Repo.call!("relay_fn.attempt_finish", [
        attrs.delivery_id,
        attrs.attempt_no,
        Atom.to_string(attrs.state),
        Map.get(attrs, :failure_class),
        Map.get(attrs, :raw_code),
        Map.get(attrs, :provider_message_id),
        attrs.event_id,
        attrs.occurred_at,
        Map.get(attrs, :delivery_rank),
        Map.get(attrs, :traceparent)
      ])

    {Repo.code!(row["result"], [:applied, :duplicate_ignored, :already_terminal, :not_found]),
     projection(row["projection_result"])}
  end

  # C-32
  # OP-3
  # OP-4
  @doc "Appends a ledger event and applies its effect to the delivery projection."
  @spec ledger_append([term()]) ::
          {atom(), non_neg_integer() | nil, non_neg_integer() | nil}
  def ledger_append(params) when length(params) == 17 do
    [row] = Repo.call!("relay_fn.ledger_append", params)

    {Repo.code!(row["result"], @ledger_results), row["delivery_rank"], row["projection_version"]}
  end

  # C-2
  # OP-3
  @doc "Rebuilds a delivery projection from its ledger and returns the differing columns; empty means none."
  @spec projection_rebuild(Relay.Id.t()) :: [{String.t(), String.t() | nil, String.t() | nil}]
  def projection_rebuild(delivery_id) do
    for row <- Repo.call!("relay_fn.delivery_projection_rebuild", [delivery_id]),
        do: {row["column_name"], row["stored"], row["rebuilt"]}
  end

  # OP-3
  @doc "Lists up to `limit` delivery identifiers of the established scope after `after_id`, in identifier order."
  @spec delivery_ids_after(Relay.Id.t() | nil, pos_integer()) :: [Relay.Id.t()]
  def delivery_ids_after(after_id, limit) do
    for %{"id" => id} <-
          all(
            "SELECT tenant_id, environment, id FROM relay.deliveries WHERE $1::uuid IS NULL OR id > $1::uuid ORDER BY id LIMIT $2",
            [after_id, limit]
          ),
        do: id
  end

  # C-88
  # OP-38
  @doc "Appends a closed UTC day's usage row; the same key with other figures is a conflict and changes nothing."
  @spec usage_record_append(map()) :: :recorded | :duplicate | :conflict | :day_open
  def usage_record_append(u) do
    [row] =
      Repo.call!("relay_fn.usage_record_append", [
        u.id,
        u.usage_day,
        Atom.to_string(u.channel),
        u.provider,
        Map.get(u, :destination_country),
        Map.get(u, :destination_operator),
        Map.get(u, :whatsapp_category),
        Atom.to_string(u.outcome),
        u.is_test,
        u.quantity,
        u.attempt_count,
        Map.get(u, :sms_segments),
        Map.get(u, :cost_micros),
        Map.get(u, :currency)
      ])

    Repo.code!(row["usage_record_append"], [:recorded, :duplicate, :conflict, :day_open])
  end

  @doc "Reads a notification of the established scope."
  @spec notification(Relay.Id.t()) :: map() | nil
  def notification(id) do
    one(
      "SELECT tenant_id, environment, id, recipient_id, subtenant_id, dedup_key, message_class, state, duplicate_count, created_at FROM relay.notifications WHERE id = $1",
      [id]
    )
  end

  @doc "Reads a delivery of the established scope."
  @spec delivery(Relay.Id.t()) :: map() | nil
  def delivery(id) do
    one(
      "SELECT tenant_id, environment, id, notification_id, channel, target_kind, provider, provider_account_id, decision, decision_reason, decision_rule_id, delivery_rank, failure_kind, failure_class, failure_rule_id, attempt_count, late_event_count, has_conflict, duplicate_delivered, projection_version, paused_at, pause_rule_id, pause_kill_switch_id, replay_depth, replay_dead_letter_id FROM relay.deliveries WHERE id = $1",
      [id]
    )
  end

  @doc "Reads the ledger of a delivery in receive order."
  @spec ledger(Relay.Id.t()) :: [map()]
  def ledger(delivery_id) do
    all(
      "SELECT tenant_id, environment, id, delivery_id, attempt_no, actor, event_type, raw_code, occurred_at, received_at, projection_result FROM relay.delivery_events WHERE delivery_id = $1 ORDER BY received_at, id",
      [delivery_id]
    )
  end

  defp to_text(value) when is_atom(value), do: Atom.to_string(value)
  defp to_text(value) when is_binary(value), do: value

  defp projection(nil), do: nil

  defp projection(text),
    do: Repo.code!(text, [:applied, :stale_ignored, :conflict_flagged, :duplicate_ignored])

  defp one(sql, params), do: sql |> all(params) |> List.first()

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
