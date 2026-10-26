defmodule Relay.Platform.Fairness.Queueing do
  @moduledoc """
  How a job enters its lane, and the dispatcher's step.

  A job of `l0` or `l1` is inserted into its Oban queue directly, inside the caller's scoped transaction; `l0` never waits for anything. A job of `l2` or `l3` is written to the tenant wait table in the same transaction; cancelling the record behind it marks the waiting row `cancelled`, so it never reaches the queue. There is no queue per tenant: fairness lives in the wait table in front of the lane's queue.

  The dispatcher step tops each bulk lane's queue up to its target depth (twice the lane's per-node budget times the nodes executing jobs, at least one) with DRR rounds, skips a lane whose load shedding is engaged so that its waiting jobs stay where they are, and refreshes the tenant weights from the settings once a minute. Telemetry: `[:relay, :fairness, :dispatched]` with the count per lane.
  """

  alias Relay.Platform.Fairness.Drr
  alias Relay.Platform.Fairness.Job
  alias Relay.Platform.Fairness.Store
  alias Relay.Platform.Lane
  alias Relay.Platform.LoadShed

  @fair_lanes [:l2, :l3]
  @weights_every_ms 60_000

  @type step_result :: %{
          dispatched: %{optional(Lane.t()) => non_neg_integer()},
          weights_at: integer()
        }

  # T-21 (2)
  # T-21 (4)
  # T-91 (2)
  # TN-51
  # TN-54
  @doc """
  Puts a job into its lane inside the caller's scoped transaction. Returns `{:ok, :queued}` for a job inserted into its queue, `{:ok, :waiting}` for a job written to the wait table and `{:ok, :exists}` when that wait row already exists. `:queued_cap` limits the tenant's waiting jobs in the lane (default `Relay.Platform.Fairness.Drr.queued_cap/0`).
  """
  @spec enqueue(Job.t(), keyword()) ::
          {:ok, :queued | :waiting | :exists} | {:error, Relay.Error.t()}
  def enqueue(%Job{} = job, opts \\ []) do
    validate!(job)

    if Lane.fair?(job.lane) do
      job
      |> Store.enqueue(Keyword.get(opts, :queued_cap, Drr.queued_cap()))
      |> enqueued()
    else
      :ok = Store.insert_now(job)
      {:ok, :queued}
    end
  end

  defp enqueued(:enqueued), do: {:ok, :waiting}
  defp enqueued(:exists), do: {:ok, :exists}

  defp enqueued(:queued_cap_exceeded),
    do: {:error, Relay.Error.new(:queued_cap_exceeded, "too many waiting jobs in the lane")}

  defp enqueued(:tenant_inactive),
    do: {:error, Relay.Error.new(:tenant_inactive, "the tenant is not active")}

  defp validate!(%Job{lane: lane, worker: worker, args: args, cost: cost, priority: priority})
       when lane in [:l0, :l1, :l2, :l3] and is_atom(worker) and is_map(args) and
              is_integer(priority) and priority >= 0 and priority <= 9 do
    unless Drr.valid_cost?(cost),
      do: raise(ArgumentError, "a job costs from 1 to #{Drr.quantum()} deliveries")

    :ok
  end

  defp validate!(job), do: raise(ArgumentError, "invalid lane job: #{inspect(job.lane)}")

  # T-21 (3)
  @doc "Cancels the waiting jobs behind a record inside the caller's scoped transaction; returns how many rows were cancelled."
  @spec cancel(String.t(), Relay.Id.t(), String.t()) :: {:ok, non_neg_integer()}
  def cancel(ref_kind, ref_id, rule_id) do
    {_result, count} = Store.cancel(ref_kind, ref_id, rule_id)
    {:ok, count}
  end

  # T-21 (2)
  # T-91 (1)
  @doc "Tops a bulk lane's queue up to its target depth with DRR rounds and returns how many jobs moved."
  @spec dispatch(Lane.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :not_leader | {:error, Relay.Error.t()}
  def dispatch(lane, fencing_token, nodes) when lane in @fair_lanes do
    target = Drr.target_depth(Lane.budget(Lane.queue(lane)), nodes)

    with {:ok, depth} <- Store.available(Lane.lane_queues(lane), target),
         do: fill(lane, fencing_token, target - depth, 0)
  end

  defp fill(_lane, _token, need, total) when need <= 0, do: {:ok, total}

  defp fill(lane, token, need, total) do
    case Store.take(lane, token, Drr.quantum(), need) do
      {:ok, 0} -> {:ok, total}
      {:ok, taken} -> fill(lane, token, need - taken, total + taken)
      other -> other
    end
  end

  # T-21 (2)
  # T-21 (5)
  # T-34 (2)
  # T-12
  @doc "One step of the `drr_dispatcher` singleton task at wall-clock time `now_ms`; `weights_at` is when the weights were last refreshed."
  @spec step(pos_integer(), integer() | nil, integer()) ::
          {:ok, step_result()} | :not_leader | {:error, Relay.Error.t()}
  def step(fencing_token, weights_at, now_ms) do
    with {:ok, executing} <- Store.executing_nodes(),
         {:ok, weights_at} <- refresh(fencing_token, weights_at, now_ms),
         {:ok, dispatched} <- dispatch_lanes(fencing_token, max(executing, 1)) do
      {:ok, %{dispatched: dispatched, weights_at: weights_at}}
    end
  end

  defp refresh(token, weights_at, now_ms)
       when not is_integer(weights_at) or now_ms - weights_at >= @weights_every_ms do
    Enum.reduce_while(@fair_lanes, {:ok, now_ms}, fn lane, acc ->
      case Store.refresh_weights(lane, token) do
        {:ok, _updated} -> {:cont, acc}
        other -> {:halt, other}
      end
    end)
  end

  defp refresh(_token, weights_at, _now_ms), do: {:ok, weights_at}

  defp dispatch_lanes(token, nodes) do
    Enum.reduce_while(@fair_lanes, {:ok, %{}}, fn lane, {:ok, acc} ->
      case dispatch_unless_shed(lane, token, nodes) do
        {:ok, count} -> {:cont, {:ok, Map.put(acc, lane, count)}}
        other -> {:halt, other}
      end
    end)
  end

  defp dispatch_unless_shed(lane, token, nodes) do
    if LoadShed.engaged?(lane) do
      {:ok, 0}
    else
      with {:ok, count} <- dispatch(lane, token, nodes) do
        :telemetry.execute([:relay, :fairness, :dispatched], %{count: count}, %{lane: lane})
        {:ok, count}
      end
    end
  end
end
