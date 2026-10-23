defmodule Relay.Delivery.Store do
  @moduledoc """
  Data access for deliveries after acceptance: cancellation, attempts, the ledger, usage records and projection checks. Every function runs inside `Relay.Repo.in_scope/3`; writes call the `relay_fn` functions.
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
       :attempt_active,
       :tenant_inactive
     ]), row["attempt_no"]}
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
      "SELECT tenant_id, environment, id, notification_id, channel, target_kind, decision, decision_reason, decision_rule_id, delivery_rank, failure_kind, failure_rule_id, attempt_count, late_event_count, has_conflict, duplicate_delivered, projection_version FROM relay.deliveries WHERE id = $1",
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

  defp projection(nil), do: nil

  defp projection(text),
    do: Repo.code!(text, [:applied, :stale_ignored, :conflict_flagged, :duplicate_ignored])

  defp one(sql, params), do: sql |> all(params) |> List.first()

  defp all(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end
end
