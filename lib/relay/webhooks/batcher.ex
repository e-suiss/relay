defmodule Relay.Webhooks.Batcher do
  @moduledoc """
  Batched delivery to an object store (WH-21, WH-52). The messages of an object store endpoint are not written one by one: an attempt puts its message into the endpoint's open batch and gives it back to wait, without using an attempt. A batch closes at the first of its age, its size and its event count (`Relay.Webhooks.Batch`, `Relay.Webhooks.Settings.batch/0`); an event that no longer fits closes the batch and opens the next one, and an event larger than the size limit is a batch of its own. The write of a batch is a job of its own (`Relay.Webhooks.BatchWorker`), queued with the batch for the time its age closes it and again at once when it closes early.

  A write claims the batch and locks every member that is not terminal, in one transaction, and asks the endpoint's circuit breaker once. Outside any transaction it builds each member's structured body, in the order of the message identifiers, and writes them as one object of CloudEvents JSON lines through the endpoint's destination. The object's name comes from the batch identifier alone, so writing a batch again writes the same object. The answer is then settled for every member in one transaction: each gets its attempt log row and its next state by the rules of a single attempt (`Relay.Webhooks.Engine.settle_member/3`), the endpoint's health hears of one result, and the batch ends `written` with the name and digest of its object, or `failed`. A member that is tried again joins the batch that is open then.

  A write that crashed leaves its members locked and its batch closed. Once the locks ran out the sweep queues the write again (`requeue_overdue/1`), which claims the same members and writes the same object. A test message and a resend are not batched: each is written at once as an object of one line.

  Telemetry: `[:relay, :webhooks, :batch]` with `count`, `events`, `bytes` and `duration_ms`, tagged with the `result` of the write.
  """

  alias Relay.Scope
  alias Relay.Webhooks.Batch
  alias Relay.Webhooks.BatchStore
  alias Relay.Webhooks.BatchWorker
  alias Relay.Webhooks.Engine
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Health
  alias Relay.Webhooks.Settings

  @lock_ms 600_000
  @busy_s 30
  @grace_s 60
  @rescued 50

  @type result :: :done | {:retry_in, pos_integer()} | {:written, atom(), non_neg_integer()}

  # WH-21
  @doc "Whether the message of a delivery waits for a batch: a message of an object store endpoint that is not a test."
  @spec batched?(map()) :: boolean()
  def batched?(%{endpoint: %{"kind" => "s3"}, message: %{"origin" => origin}}),
    do: origin != "test"

  def batched?(_delivery), do: false

  # WH-21
  # WH-29
  @doc "Puts the claimed message of `run` into its endpoint's open batch. A message whose body cannot be built is settled like a single attempt."
  @spec join(map()) :: Engine.result()
  def join(%{scope: scope, delivery: delivery} = run) do
    now = run.clock.()

    case Engine.prepare(scope, delivery, now) do
      {:ok, sent} -> joined(run, sent.prepared.body, now)
      {:error, result, sent} -> {:attempted, Engine.conclude(run, result, sent, {now, 0})}
    end
  end

  defp joined(%{scope: scope, delivery: %{message: message}} = run, body, now) do
    work = fn _status ->
      case BatchStore.membership(message["id"]) do
        nil -> added(run, body, now)
        %{"closes_at" => at} -> waiting(run, at, now)
      end
    end

    _ = EngineStore.in_scope(scope, work)
    :done
  end

  defp waiting(%{delivery: %{message: message}, token: token}, at, now) do
    state = if message["attempt_count"] == 0, do: "pending", else: "scheduled"
    EngineStore.park(message["id"], token, state, nil, at, now)
  end

  defp added(%{delivery: %{message: message, endpoint: endpoint}} = run, body, now) do
    limits = run.limits
    {id, batch} = open(endpoint["id"], body, now, limits)
    grown = Batch.add(batch, body)
    close? = Batch.close_reason(grown, now, limits) != nil
    closes_at = Batch.closes_at(batch, limits)
    bytes = grown.bytes - batch.bytes
    at = if close?, do: now, else: closes_at

    with :added <- BatchStore.add(message["id"], run.token, id, closes_at, bytes, close?, now) do
      if close? or batch.events == 0, do: job(id, at)
      :added
    end
  end

  defp open(endpoint_id, body, now, limits) do
    case BatchStore.open_lock(endpoint_id) do
      nil -> fresh(now)
      row -> fitting(row, body, now, limits)
    end
  end

  defp fitting(%{"id" => id} = row, body, now, limits) do
    batch = %Batch{
      id: Relay.Id.to_string(id),
      opened_at: row["opened_at"],
      bytes: row["byte_count"],
      events: row["event_count"]
    }

    if Batch.accepts?(batch, body, limits) and Batch.close_reason(batch, now, limits) == nil do
      {id, batch}
    else
      _closed = BatchStore.close(id, now)
      :ok = job(id, now)
      fresh(now)
    end
  end

  defp fresh(now) do
    id = Relay.Id.generate()
    {id, Batch.open(Relay.Id.to_string(id), now)}
  end

  # T-15
  @doc "Queues the write of a batch for `at`, inside the caller's scoped transaction."
  @spec job(Relay.Id.t(), DateTime.t() | nil) :: :ok | {:error, term()}
  def job(batch_id, at) do
    args =
      EngineStore.current_scope()
      |> Scope.to_job_args()
      |> Map.put("batch_id", Relay.Id.to_string(batch_id))

    Settings.runtime().enqueue(%{
      worker: BatchWorker,
      args: args,
      ref_id: batch_id,
      scheduled_at: at
    })
  end

  # WH-21
  # WH-32 (4)
  @doc "Queues the write of every batch of the caller's scope that was to be written at or before `now` less a grace time and is neither written nor failed; returns how many. Runs inside the caller's scoped transaction."
  @spec requeue_overdue(DateTime.t()) :: non_neg_integer()
  def requeue_overdue(%DateTime{} = now) do
    now
    |> DateTime.add(-@grace_s, :second)
    |> BatchStore.overdue(@rescued)
    |> Enum.count(fn %{"id" => id} -> job(id, now) == :ok end)
  end

  # WH-18
  # WH-21
  @doc "Writes a batch once and settles its members. Option `:clock` is the function the write reads the time from. Returns `{:written, result, members}` with the result of the write and the number of members it settled, `:done` when there was nothing to write, or `{:retry_in, seconds}` while the batch is not due or another write holds it."
  @spec write(Scope.t(), Relay.Id.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def write(%Scope{} = scope, batch_id, opts \\ []) do
    clock = Keyword.get(opts, :clock, &Relay.Clock.utc_now/0)
    token = Relay.Id.generate()
    work = fn _status -> claimed(batch_id, token, clock.()) end

    case EngineStore.in_scope(scope, work) do
      {:ok, {:run, run}} ->
        {:ok, written(Map.merge(run, %{scope: scope, token: token, clock: clock}))}

      {:ok, other} ->
        {:ok, other}

      {:error, {:breaker_open, at}} ->
        postponed(scope, batch_id, at)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claimed(batch_id, token, now) do
    until = DateTime.add(now, @lock_ms, :millisecond)

    case BatchStore.claim(batch_id, token, until, now) do
      {:claimed, ids} -> admitted(BatchStore.batch(batch_id), ids, now)
      {:not_due, _none} -> {:retry_in, wait_s(BatchStore.batch(batch_id), now)}
      {:locked, _none} -> {:retry_in, @busy_s}
      {_other, _none} -> :done
    end
  end

  defp wait_s(%{"closes_at" => at}, now), do: max(DateTime.diff(at, now, :second), 1)

  # WH-35
  defp admitted(%{"endpoint_id" => endpoint_id} = batch, ids, now) do
    endpoint = EngineStore.endpoint(endpoint_id)
    health = EngineStore.health_lock(endpoint_id)

    case Health.admit(health, now, Settings.health()) do
      {{:reject, wait_ms}, _unchanged} ->
        EngineStore.rollback({:breaker_open, DateTime.add(now, wait_ms, :millisecond)})

      {decision, changed} ->
        if changed, do: EngineStore.health_save(endpoint_id, Health.columns(changed), now)
        members = members(ids, endpoint)
        {:run, %{batch: batch, endpoint: endpoint, decision: decision, members: members}}
    end
  end

  # WH-12
  defp members(ids, %{"id" => endpoint_id} = endpoint) do
    messages = ids |> EngineStore.messages() |> Enum.sort_by(& &1["id"])
    events = messages |> Enum.map(& &1["event_id"]) |> Enum.uniq() |> EngineStore.events()
    events = Map.new(events, &{&1["id"], &1})

    versions =
      messages
      |> Enum.map(& &1["endpoint_version"])
      |> Enum.uniq()
      |> Map.new(&{&1, EngineStore.endpoint_version(endpoint_id, &1)})

    for message <- messages do
      %{
        message: message,
        event: Map.fetch!(events, message["event_id"]),
        endpoint: endpoint,
        version: Map.fetch!(versions, message["endpoint_version"])
      }
    end
  end

  # WH-35 (2)
  defp postponed(scope, batch_id, at) do
    with {:ok, _queued} <- EngineStore.in_scope(scope, fn _status -> job(batch_id, at) end),
         do: {:ok, :done}
  end

  defp written(%{scope: scope, members: members} = run) do
    started = run.clock.()
    clock = Relay.Clock.monotonic_ms()
    lines = Enum.map(members, &{&1, Engine.prepare(scope, &1, started)})
    object = object(run, for({_member, {:ok, sent}} <- lines, do: sent.prepared.body))
    answer = put(run, object)
    timing = {started, max(Relay.Clock.monotonic_ms() - clock, 0)}
    now = run.clock.()
    write = answer && Engine.record(answer, nil, timing, now)
    work = fn _status -> settled(run, lines, write, object, timing, now) end

    case EngineStore.in_scope(scope, work) do
      {:ok, count} ->
        measure(write, object, count)
        {:written, result(write), count}

      {:error, _reason} ->
        {:written, :unsettled, 0}
    end
  end

  # WH-21
  defp object(_run, []), do: nil

  defp object(%{batch: batch}, bodies) do
    name = Relay.ExternalId.encode("whb", batch["id"])

    case Batch.prepared(name, bodies, max(batch["attempt_count"], 1)) do
      {:ok, object} -> object
      {:error, _not_a_line} -> :invalid
    end
  end

  defp put(_run, nil), do: nil

  defp put(_run, :invalid),
    do: {:error, %{class: :invalid, reason: "batch_invalid", duration_ms: 0, address: nil}}

  defp put(%{scope: scope, endpoint: endpoint}, object),
    do: Engine.dispatch(scope, endpoint, object)

  # WH-10
  defp settled(run, lines, write, object, timing, now) do
    count = Enum.count(lines, &member(run, &1, write, timing, now))
    if write, do: Engine.endpoint_result(run.endpoint, write.outcome, run.decision, now)
    finished(run, write, object, now)
    count
  end

  defp member(run, {delivery, line}, write, timing, now) do
    attempt =
      case line do
        {:ok, sent} -> %{write | sent: sent}
        {:error, failed, sent} -> Engine.record(failed, sent, put_elem(timing, 1, 0), now)
      end

    run = %{
      scope: run.scope,
      delivery: delivery,
      token: run.token,
      decision: run.decision,
      manual?: false,
      batched?: true,
      clock: run.clock
    }

    Engine.settle_member(run, attempt, now) != :lock_lost
  end

  defp finished(%{batch: batch, endpoint: endpoint}, write, object, now) do
    if result(write) == :delivered do
      key = Batch.object_key(endpoint["destination"]["prefix"], object.id)
      digest = :crypto.hash(:sha256, object.body)
      BatchStore.finish(batch["id"], "written", key, digest, now)
    else
      BatchStore.finish(batch["id"], "failed", nil, nil, now)
    end
  end

  defp result(nil), do: :empty
  defp result(%{outcome: outcome}), do: outcome.result

  defp measure(write, object, count) do
    :telemetry.execute(
      [:relay, :webhooks, :batch],
      %{
        count: 1,
        events: count,
        bytes: bytes(object),
        duration_ms: if(write, do: write.duration_ms, else: 0)
      },
      %{result: Atom.to_string(result(write))}
    )
  end

  defp bytes(%{body: body}), do: byte_size(body)
  defp bytes(_none), do: 0
end
