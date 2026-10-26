defmodule Relay.Platform.Queue.PrunerStore do
  @moduledoc """
  Removal of finished job rows from `relay_queue.oban_jobs` and of expired rows from the ephemeral `relay_queue` tables, only through `Relay.QueueRepo` as the `relay_queue` role. Only `completed` and `cancelled` jobs go; a `discarded` row stays until its dead-letter record exists (OP-12). An ephemeral table carries only identifiers, digests and counts; its rows go once the table's two prune policies let the `relay_queue` role see them, an hour after they expire (OP-74). Each ephemeral entry is the table name and its own `DELETE` statement, which takes the row limit as `$1`.
  """

  alias Relay.QueueRepo

  @prune """
  DELETE FROM relay_queue.oban_jobs WHERE id IN (
    SELECT id FROM relay_queue.oban_jobs
    WHERE (state = 'completed' AND completed_at < $1) OR (state = 'cancelled' AND cancelled_at < $2)
    ORDER BY id LIMIT $3
  )
  """

  @ephemeral []

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

  # OP-74
  @doc "The ephemeral `relay_queue` tables this cleaner prunes, in order."
  @spec ephemeral_tables() :: [String.t()]
  def ephemeral_tables, do: Enum.map(@ephemeral, &elem(&1, 0))

  # OP-74
  # OP-12
  @doc "Deletes at most `limit` expired rows from each ephemeral table and returns the count per table."
  @spec prune_ephemeral(pos_integer()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, String.t(), Exception.t()}
  def prune_ephemeral(limit) when is_integer(limit) and limit > 0 do
    @ephemeral
    |> Enum.reduce_while({:ok, []}, fn {table, sql}, {:ok, acc} ->
      case QueueRepo.query(sql, [limit]) do
        {:ok, %{num_rows: rows}} -> {:cont, {:ok, [{table, rows} | acc]}}
        {:error, error} -> {:halt, {:error, table, error}}
      end
    end)
    |> case do
      {:ok, counts} -> {:ok, Enum.reverse(counts)}
      {:error, _table, _error} = error -> error
    end
  end
end
