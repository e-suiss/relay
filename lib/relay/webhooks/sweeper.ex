defmodule Relay.Webhooks.Sweeper do
  @moduledoc """
  The sweep of the delivery engine in one scope, in one transaction (WH-27, WH-28, WH-32 (4), WH-36):

    * a message whose lock ran out, because the worker that held it crashed, is made due again and gets a new job;
    * a message that is due for longer than the overdue time without having started gets a new job, so a lost job costs time and never a message;
    * a message held past its delivery time becomes `expired`, and one that waited behind an open circuit breaker past its window becomes `window_exceeded` with the tenant's alarm; messages held for a paused or disabled endpoint stay where they are and are never dropped (WH-37);
    * an endpoint whose uninterrupted failure reached the warning or the disable time is warned about or disabled, also when no attempt happens at that moment;
    * an object store batch that was to be written and is neither written nor failed, because its job was lost or its writer crashed, gets a new write job, which claims the same members and writes the same object (WH-21). A message that waits in such a batch is left to it.

  Telemetry: `[:relay, :webhooks, :backlog]` with `age_ms`, the age of the scope's oldest message that waits for an attempt (WH-28 (1)), and `[:relay, :webhooks, :sweep]` with the counts of what the sweep did.
  """

  alias Relay.Scope
  alias Relay.Webhooks.Batcher
  alias Relay.Webhooks.Engine
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Fanout
  alias Relay.Webhooks.Health
  alias Relay.Webhooks.Settings

  @overdue_s 900
  @batch 200
  @window "window_exceeded"

  @type counts :: %{
          rescued: non_neg_integer(),
          requeued: non_neg_integer(),
          expired: non_neg_integer(),
          window_exceeded: non_neg_integer(),
          batches: non_neg_integer()
        }

  # WH-28
  @doc "Sweeps every scope that has work, at most `limit` of them; returns how many were swept."
  @spec run(pos_integer()) :: non_neg_integer()
  def run(limit \\ 100) do
    Relay.Clock.utc_now()
    |> EngineStore.due_scopes(limit)
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Scope.new(tenant_id, environment),
           {:ok, _counts} <- scope(scope) do
        true
      else
        _failed -> false
      end
    end)
  end

  # WH-21
  # WH-27
  # WH-28
  # WH-32 (4)
  # WH-36
  @doc "Sweeps one scope and returns what it did."
  @spec scope(Scope.t()) :: {:ok, counts()} | {:error, term()}
  def scope(%Scope{} = scope) do
    result =
      EngineStore.in_scope(scope, fn _status ->
        now = Relay.Clock.utc_now()
        overdue = DateTime.add(now, -@overdue_s, :second)
        due = now |> EngineStore.due(overdue, @batch) |> Enum.group_by(& &1["action"])

        counts = %{
          rescued: requeued(due["rescue"], "rescue", now),
          requeued: requeued(due["overdue"], "nudge", now),
          expired: ended(due["expired"], "expired", "ttl_expired", now),
          window_exceeded: ended(due["window_exceeded"], "window_exceeded", @window, now),
          batches: Batcher.requeue_overdue(now)
        }

        failing(now)
        {counts, EngineStore.oldest_waiting(), now}
      end)

    with {:ok, {counts, oldest, now}} <- result do
      :telemetry.execute([:relay, :webhooks, :sweep], counts, %{})
      :telemetry.execute([:relay, :webhooks, :backlog], %{age_ms: age_ms(oldest, now)}, %{})
      {:ok, counts}
    end
  end

  defp age_ms(nil, _now), do: 0
  defp age_ms(oldest, now), do: max(DateTime.diff(now, oldest, :millisecond), 0)

  defp requeued(nil, _mode, _now), do: 0

  defp requeued(rows, mode, now) do
    rows
    |> Enum.map(&%{id: &1["id"], next_attempt_at: now})
    |> EngineStore.requeue(mode, now)
    |> Enum.count(fn %{"message_id" => id} -> Fanout.attempt_job(id, now) == :ok end)
  end

  defp ended(nil, _state, _reason, _now), do: 0

  defp ended(rows, state, reason, now) do
    ended = EngineStore.terminate(Enum.map(rows, & &1["id"]), state, reason, nil, now)
    if state == "window_exceeded", do: Enum.each(ended, &alarm/1)
    length(ended)
  end

  # WH-28 (2)
  defp alarm(%{"message_id" => id, "endpoint_id" => endpoint_id, "event_id" => event_id}) do
    event_id = event_id |> EngineStore.event() |> Engine.webhook_id()
    Engine.alarm(endpoint_id, event_id, id)
  end

  # WH-36
  defp failing(now) do
    params = Settings.health()
    since = DateTime.add(now, -params.warn_after_ms, :millisecond)

    for %{"endpoint_id" => id} <- EngineStore.failing(since) do
      row = EngineStore.health_lock(id)
      endpoint = EngineStore.endpoint(id)
      effects = Health.due(row, endpoint["auto_disable"], now, params)

      if :warn in effects do
        warned = Map.put(row, "warned_at", now)
        :saved = EngineStore.health_save(id, Health.columns(warned), now)
      end

      Enum.each(effects, &Engine.effect(&1, id, row, now))
    end

    :ok
  end
end
