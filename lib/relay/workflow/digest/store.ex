defmodule Relay.Workflow.Digest.Store do
  @moduledoc """
  Data access of digest windows and their items through the `relay_fn.digest_*` functions, and the cross-tenant discovery of scopes with a window to fire or plan through `relay_ops.digest_due_scopes`. Every function except `in_scope/2` and `due_scopes/1` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @add [:opened, :added, :exists, :recipient_not_found]
  @plan [:schedule, :kept, :not_open, :not_found]
  @fire [:fired, :empty, :not_due, :not_open, :not_found]

  @window """
  SELECT w.id, w.recipient_id, w.window_key, w.generation, w.chain_start, w.origin,
    w.window_mode, w.leading_mode, w.debounce_ms, w.max_wait_ms, w.schedule_rule, w.time_zone,
    w.release_at, w.max_items, w.state, w.item_count, w.cumulative_count, w.first_at, w.last_at,
    w.deadline_at, w.fire_at, w.timer_at, w.closed_at, w.close_reason, w.read_at
  FROM relay.digest_windows w
  WHERE w.tenant_id = relay_private.ctx_tenant_id()
    AND w.environment = relay_private.ctx_environment() AND w.id = $1
  """

  @chain """
  SELECT i.notification_id, i.delivery_id, i.actor_digest, i.occurred_at
  FROM relay.digest_items i
  JOIN relay.digest_windows w ON w.tenant_id = i.tenant_id AND w.environment = i.environment
    AND w.id = i.window_id
  WHERE w.tenant_id = relay_private.ctx_tenant_id()
    AND w.environment = relay_private.ctx_environment() AND w.recipient_id = $1
    AND w.window_key = $2 AND w.generation BETWEEN $3 AND $4 AND NOT i.sent_alone
  """

  @actors """
  SELECT count(DISTINCT i.actor_digest)
  FROM relay.digest_items i
  JOIN relay.digest_windows w ON w.tenant_id = i.tenant_id AND w.environment = i.environment
    AND w.id = i.window_id
  WHERE w.tenant_id = relay_private.ctx_tenant_id()
    AND w.environment = relay_private.ctx_environment() AND w.recipient_id = $1
    AND w.window_key = $2 AND w.generation BETWEEN $3 AND $4 AND NOT i.sent_alone
  """

  @anchor """
  SELECT i.notification_id, i.delivery_id
  FROM relay.digest_items i
  WHERE i.tenant_id = relay_private.ctx_tenant_id()
    AND i.environment = relay_private.ctx_environment() AND i.window_id = $1
    AND NOT i.sent_alone
  ORDER BY i.seq
  LIMIT 1
  """

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Queues a job inside the current transaction; rolls the transaction back when it is not queued."
  @spec insert_job!(Ecto.Changeset.t()) :: :ok
  def insert_job!(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:job_not_queued, reason})
    end
  end

  # WF-27
  # INV-3
  # INV-12
  @doc "Writes an item into the open window of its key, opening the next window when none is open; see `relay_fn.digest_item_add`."
  @spec add(map()) :: map()
  def add(attrs) do
    [row] =
      Repo.call!("relay_fn.digest_item_add", [
        attrs.window_id,
        attrs.item_id,
        attrs.recipient_id,
        attrs.window_key,
        attrs.origin,
        Atom.to_string(attrs.config.mode),
        Atom.to_string(attrs.config.leading),
        attrs.config.debounce_ms,
        attrs.config.max_wait_ms,
        attrs.config.schedule,
        attrs.time_zone,
        attrs.config.release_at,
        attrs.config.max_items,
        attrs.max_open_ms,
        attrs.notification_id,
        attrs.delivery_id,
        attrs.actor_digest
      ])

    %{
      result: Repo.code!(row["result"], @add),
      window_id: row["window_id"],
      generation: row["generation"],
      seq: row["item_seq"],
      sent_alone: row["sent_alone"],
      item_count: row["item_count"],
      first_at: row["first_at"],
      last_at: row["last_at"]
    }
  end

  # WF-27
  @doc "Sets the firing time of an open window; `:schedule` when a timer job must be queued for it."
  @spec plan(Relay.Id.t(), DateTime.t()) :: {atom(), DateTime.t() | nil}
  def plan(window_id, fire_at) do
    [row] = Repo.call!("relay_fn.digest_window_plan", [window_id, fire_at])
    {Repo.code!(row["result"], @plan), row["fire_at"]}
  end

  # WF-26
  # WF-29
  @doc "Closes a due window as fired or empty, or returns `:not_due` with its firing time."
  @spec fire(Relay.Id.t()) :: map()
  def fire(window_id) do
    [row] = Repo.call!("relay_fn.digest_window_fire", [window_id])

    %{
      result: Repo.code!(row["result"], @fire),
      next_at: row["next_at"],
      item_count: row["item_count"],
      cumulative_count: row["cumulative_count"],
      chain_start: row["chain_start"]
    }
  end

  # WF-27
  @doc "Applies a recipient's read signal for a notification: cancels the open windows of its keys and marks the fired ones read."
  @spec read(Relay.Id.t(), Relay.Id.t()) :: [{Relay.Id.t(), :cancelled | :read}]
  def read(recipient_id, notification_id) do
    for row <- Repo.call!("relay_fn.digest_read", [recipient_id, notification_id]),
        do: {row["window_id"], Repo.code!(row["result"], [:cancelled, :read])}
  end

  # WF-27
  # T-24
  @doc "Lists the open windows of the established scope that are due or have no timer."
  @spec due(pos_integer()) :: [Relay.Id.t()]
  def due(limit) do
    for row <- Repo.call!("relay_fn.digest_due", [limit]), do: row["window_id"]
  end

  # WF-27
  # TN-13 (4)
  @doc "Lists the scopes that have an open window to fire or plan, through the discovery escape hatch; scopes only, no content."
  @spec due_scopes(pos_integer()) :: [{Relay.Id.t(), String.t()}]
  def due_scopes(limit) when is_integer(limit) and limit > 0 do
    for row <-
          Repo.call_unscoped!(:digest_window_discovery, "relay_ops.digest_due_scopes", [limit]),
        do: {row["tenant_id"], row["environment"]}
  end

  @doc "Reads a window."
  @spec window(Relay.Id.t()) :: map() | nil
  def window(window_id) do
    case select(@window, [window_id]) do
      [row] -> window_row(row)
      [] -> nil
    end
  end

  # WF-26
  # WF-29
  @doc "The first and last `n` digested items of a window's chain of cumulative windows, oldest first, and the number of distinct actors."
  @spec items(map(), pos_integer()) :: %{first: [map()], last: [map()], actors: non_neg_integer()}
  def items(window, n) do
    params = [window.recipient_id, window.window_key, window.chain_start, window.generation]
    first = select([@chain, "ORDER BY w.generation, i.seq LIMIT $5"], params ++ [n])
    last = select([@chain, "ORDER BY w.generation DESC, i.seq DESC LIMIT $5"], params ++ [n])
    [%{"count" => actors}] = select(@actors, params)

    %{
      first: Enum.map(first, &item_row/1),
      last: last |> Enum.reverse() |> Enum.map(&item_row/1),
      actors: actors
    }
  end

  # WF-27
  @doc "The first digested item of a window: the notification whose run sends the digest."
  @spec anchor(Relay.Id.t()) :: map() | nil
  def anchor(window_id) do
    case select(@anchor, [window_id]) do
      [row] -> %{notification_id: row["notification_id"], delivery_id: row["delivery_id"]}
      [] -> nil
    end
  end

  defp select(sql, params) do
    %Postgrex.Result{columns: columns, rows: rows} = Repo.scoped_query!(sql, params)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  defp item_row(row) do
    %{
      notification_id: row["notification_id"],
      delivery_id: row["delivery_id"],
      actor_digest: row["actor_digest"],
      occurred_at: row["occurred_at"]
    }
  end

  defp window_row(row) do
    %{
      id: row["id"],
      recipient_id: row["recipient_id"],
      window_key: row["window_key"],
      generation: row["generation"],
      chain_start: row["chain_start"],
      origin: row["origin"],
      mode: row["window_mode"],
      leading: row["leading_mode"],
      debounce_ms: row["debounce_ms"],
      max_wait_ms: row["max_wait_ms"],
      schedule: row["schedule_rule"],
      time_zone: row["time_zone"],
      release_at: row["release_at"],
      max_items: row["max_items"],
      state: row["state"],
      item_count: row["item_count"],
      cumulative_count: row["cumulative_count"],
      first_at: row["first_at"],
      last_at: row["last_at"],
      deadline_at: row["deadline_at"],
      fire_at: row["fire_at"],
      timer_at: row["timer_at"],
      closed_at: row["closed_at"],
      close_reason: row["close_reason"],
      read_at: row["read_at"]
    }
  end
end
