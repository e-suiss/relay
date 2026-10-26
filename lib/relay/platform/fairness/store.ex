defmodule Relay.Platform.Fairness.Store do
  @moduledoc """
  Database access of tenant fairness. Waiting jobs are written and cancelled through `relay_fn.drr_enqueue` and `relay_fn.drr_cancel` inside the caller's scoped transaction. A DRR round runs `relay_ops.drr_take` through the `:fair_dispatch` escape hatch on the bulk pool and inserts the taken jobs into Oban in the same transaction, so a job is either both dispatched and queued or neither. Queue depth and the number of nodes executing jobs are read through `Relay.QueueRepo`.
  """

  alias Relay.BulkRepo
  alias Relay.Platform.Fairness.Job
  alias Relay.QueueRepo
  alias Relay.Repo

  @enqueue_results [:enqueued, :exists, :queued_cap_exceeded, :lane_not_fair, :tenant_inactive]
  @cancel_results [:cancelled, :none]

  @doc "Writes a waiting job with `relay_fn.drr_enqueue` inside the caller's scope."
  @spec enqueue(Job.t(), pos_integer()) ::
          :enqueued | :exists | :queued_cap_exceeded | :lane_not_fair | :tenant_inactive
  def enqueue(%Job{} = job, queued_cap) do
    [%{"drr_enqueue" => result}] =
      Repo.call!("relay_fn.drr_enqueue", [
        job.id,
        Atom.to_string(job.lane),
        Atom.to_string(job.lane),
        Job.worker_name(job),
        job.args,
        job.priority,
        job.cost,
        job.scheduled_at || Relay.Clock.utc_now(),
        job.ref_kind,
        job.ref_id,
        queued_cap
      ])

    Repo.code!(result, @enqueue_results)
  end

  @doc "Inserts a critical lane job into its queue inside the caller's scope."
  @spec insert_now(Job.t()) :: :ok
  def insert_now(%Job{} = job) do
    unless Repo.current_scope(), do: raise(Relay.ScopeError, :missing)

    opts = [queue: Atom.to_string(job.lane), priority: job.priority]

    changeset =
      case job.scheduled_at do
        nil -> job.worker.new(job.args, opts)
        at -> job.args |> job.worker.new([scheduled_at: at] ++ opts) |> due(at)
      end

    {:ok, _job} = Oban.insert(changeset)
    :ok
  end

  defp due(changeset, at) do
    if DateTime.compare(at, Relay.Clock.utc_now()) == :gt,
      do: changeset,
      else: Ecto.Changeset.force_change(changeset, :state, "available")
  end

  @doc "Cancels the waiting jobs behind a record with `relay_fn.drr_cancel` inside the caller's scope."
  @spec cancel(String.t(), Relay.Id.t(), String.t()) :: {:cancelled | :none, non_neg_integer()}
  def cancel(ref_kind, ref_id, rule_id) do
    [%{"result" => result, "cancelled" => count}] =
      Repo.call!("relay_fn.drr_cancel", [ref_kind, ref_id, rule_id])

    {Repo.code!(result, @cancel_results), count}
  end

  @doc "Runs one DRR round on the bulk pool and inserts the taken jobs in the same transaction."
  @spec take(Relay.Platform.Lane.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | :not_leader | {:error, Relay.Error.t()}
  def take(lane, fencing_token, quantum, max_jobs) do
    params = [Atom.to_string(lane), fencing_token, quantum, max_jobs]

    BulkRepo.run(fn -> Repo.transaction(fn -> take_round(params) end) end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, :not_leader} -> :not_leader
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> failure(error)
  end

  @doc "Refreshes the tenant weights of a lane from the settings."
  @spec refresh_weights(Relay.Platform.Lane.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | :not_leader | {:error, Relay.Error.t()}
  def refresh_weights(lane, fencing_token) do
    BulkRepo.run(fn ->
      Repo.call_unscoped!(:fair_dispatch, "relay_ops.drr_weights_refresh", [
        Atom.to_string(lane),
        fencing_token
      ])
    end)
    |> case do
      [%{"result" => "refreshed", "updated" => count}] -> {:ok, count}
      [%{"result" => "not_leader"}] -> :not_leader
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> failure(error)
  end

  @doc "Counts the available jobs of the queues, up to `limit`."
  @spec available([String.t()], pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def available(queues, limit) do
    "SELECT count(*) FROM (SELECT 1 FROM relay_queue.oban_jobs WHERE state = 'available' AND queue = ANY($1) LIMIT $2) AS a"
    |> QueueRepo.query([queues, limit])
    |> case do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, error} -> failure(error)
    end
  rescue
    error in DBConnection.ConnectionError -> failure(error)
  end

  @doc "Counts the nodes executing at least one job."
  @spec executing_nodes() :: {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def executing_nodes do
    "SELECT count(DISTINCT attempted_by[1]) FROM relay_queue.oban_jobs WHERE state = 'executing'"
    |> QueueRepo.query([])
    |> case do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, error} -> failure(error)
    end
  rescue
    error in DBConnection.ConnectionError -> failure(error)
  end

  defp take_round(params) do
    case Repo.call_unscoped!(:fair_dispatch, "relay_ops.drr_take", params) do
      [%{"result" => "not_leader"}] -> Repo.rollback(:not_leader)
      rows -> insert_jobs(rows)
    end
  end

  defp insert_jobs([]), do: 0

  defp insert_jobs(rows) do
    jobs = Enum.map(rows, &changeset/1)
    _ = Oban.insert_all(jobs)
    length(jobs)
  end

  defp changeset(%{"worker" => worker} = row) do
    opts = [queue: row["queue"], priority: row["priority"], scheduled_at: row["scheduled_at"]]

    changeset =
      case Oban.Worker.from_string(worker) do
        {:ok, module} -> module.new(row["args"], opts)
        {:error, _unknown} -> Oban.Job.new(row["args"], Keyword.put(opts, :worker, worker))
      end

    Ecto.Changeset.force_change(changeset, :state, "available")
  end

  defp failure(error),
    do:
      {:error,
       Relay.Error.new(:database_error, "fairness query failed", %{reason: reason(error)})}

  defp reason(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp reason(%DBConnection.ConnectionError{}), do: :connection
  defp reason(_error), do: :unexpected
end
