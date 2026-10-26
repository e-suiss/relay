defmodule Relay.Platform.LoadShed.Store do
  @moduledoc """
  Database access of load shedding. The queue delay of a lane is `now() − min(scheduled_at)` over the available jobs of its queues (the job times are UTC without a zone, so both sides are compared as epoch seconds), read through `Relay.QueueRepo` with one index probe per queue and priority on the job index `(state, queue, priority, scheduled_at, id)`, on the database clock. Transitions are written with `relay_ops.load_shed_record` under the controller's fencing token and read back with `relay_ops.load_shed_state`, both through the `:load_shed` escape hatch.
  """

  alias Relay.QueueRepo
  alias Relay.Repo

  @record_results [:recorded, :not_leader, :unchanged]

  @sample """
  SELECT (extract(epoch FROM now()) * 1000)::bigint, q.queue,
    (SELECT greatest(0, floor((extract(epoch FROM now()) - extract(epoch FROM m.oldest)) * 1000))::bigint
     FROM (SELECT min(j.scheduled_at) AS oldest
           FROM generate_series(0, 9) AS p(priority),
           LATERAL (SELECT o.scheduled_at FROM relay_queue.oban_jobs o
                    WHERE o.state = 'available' AND o.queue = q.queue AND o.priority = p.priority
                    ORDER BY o.scheduled_at LIMIT 1) AS j) AS m
     WHERE m.oldest IS NOT NULL)
  FROM unnest($1::text[]) AS q(queue)
  """

  @doc "Reads the queue delay of each queue on the database clock, `nil` for a queue without an available job, with the database time; `repo` defaults to `Relay.QueueRepo`."
  @spec sample([String.t()], module()) ::
          {:ok, integer(), %{String.t() => non_neg_integer() | nil}} | {:error, Relay.Error.t()}
  def sample(queues, repo \\ QueueRepo) do
    case repo.query(@sample, [queues]) do
      {:ok, %{rows: [[now_ms | _] | _] = rows}} ->
        {:ok, now_ms, Map.new(rows, fn [_now, queue, delay] -> {queue, delay} end)}

      {:error, error} ->
        failure(error)
    end
  rescue
    error in DBConnection.ConnectionError -> failure(error)
  end

  @doc "Records one transition under the controller's fencing token."
  @spec record(Relay.Id.t(), map(), pos_integer()) ::
          {:ok, :recorded | :unchanged} | :not_leader | {:error, Relay.Error.t()}
  def record(id, transition, fencing_token) do
    [%{"load_shed_record" => result}] =
      Repo.call_unscoped!(:load_shed, "relay_ops.load_shed_record", [
        id,
        Atom.to_string(transition.lane),
        Atom.to_string(transition.phase),
        transition.rule_id,
        transition.sample_ms,
        transition.target_ms,
        transition.interval_ms,
        fencing_token
      ])

    case Repo.code!(result, @record_results) do
      :not_leader -> :not_leader
      result -> {:ok, result}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> failure(error)
  end

  @doc "Reads the last transition of every lane."
  @spec state() :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def state do
    {:ok, Repo.call_unscoped!(:load_shed, "relay_ops.load_shed_state", [])}
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> failure(error)
  end

  defp failure(error),
    do:
      {:error,
       Relay.Error.new(:database_error, "load shedding query failed", %{reason: reason(error)})}

  defp reason(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp reason(%DBConnection.ConnectionError{}), do: :connection
  defp reason(_error), do: :unexpected
end
