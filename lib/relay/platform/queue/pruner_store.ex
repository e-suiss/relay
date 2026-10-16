defmodule Relay.Platform.Queue.PrunerStore do
  @moduledoc """
  Removal of finished job rows from `relay_queue.oban_jobs`, only through `Relay.QueueRepo` as the `relay_queue` role. Only `completed` and `cancelled` rows go; a `discarded` row stays until its dead-letter record exists (OP-12).
  """

  alias Relay.QueueRepo

  @prune """
  DELETE FROM relay_queue.oban_jobs WHERE id IN (
    SELECT id FROM relay_queue.oban_jobs
    WHERE (state = 'completed' AND completed_at < $1) OR (state = 'cancelled' AND cancelled_at < $2)
    ORDER BY id LIMIT $3
  )
  """

  # OP-12
  # T-15
  @doc "Deletes at most `limit` completed rows older than `completed_before` and cancelled rows older than `cancelled_before`."
  @spec prune(NaiveDateTime.t(), NaiveDateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, Exception.t()}
  def prune(completed_before, cancelled_before, limit) when is_integer(limit) and limit > 0 do
    case QueueRepo.query(@prune, [completed_before, cancelled_before, limit]) do
      {:ok, %{num_rows: rows}} -> {:ok, rows}
      {:error, error} -> {:error, error}
    end
  end
end
