defmodule Relay.Platform.Queue.PeerStore do
  @moduledoc """
  Queue leadership rows in `relay_queue.oban_peers`, written only through `Relay.QueueRepo` as the `relay_queue` role (OP-12). One row per Oban instance; its holder is the leader until the lease expires.
  """

  alias Relay.QueueRepo

  @expire "DELETE FROM relay_queue.oban_peers WHERE name = $1 AND expires_at < $2"
  @resign "DELETE FROM relay_queue.oban_peers WHERE name = $1 AND node = $2"
  @claim """
  INSERT INTO relay_queue.oban_peers (name, node, started_at, expires_at)
  VALUES ($1, $2, $3, $4)
  ON CONFLICT (name) DO UPDATE SET expires_at = EXCLUDED.expires_at
  WHERE relay_queue.oban_peers.node = EXCLUDED.node
  """
  @leader "SELECT node FROM relay_queue.oban_peers WHERE name = $1"

  # T-12
  # OP-12
  @doc "Removes an expired lease and takes or renews the lease; returns true if `node` leads."
  @spec elect(String.t(), String.t(), NaiveDateTime.t(), NaiveDateTime.t()) ::
          {:ok, boolean()} | {:error, term()}
  def elect(name, node, now, expires_at) do
    QueueRepo.transaction(fn ->
      QueueRepo.query!(@expire, [name, now])
      %{num_rows: rows} = QueueRepo.query!(@claim, [name, node, now, expires_at])
      rows > 0
    end)
  end

  @doc "Gives up the lease held by `node`."
  @spec resign(String.t(), String.t()) :: :ok
  def resign(name, node) do
    _ = QueueRepo.query(@resign, [name, node])
    :ok
  end

  @doc "Returns the node holding the lease, if any."
  @spec leader(String.t()) :: String.t() | nil
  def leader(name) do
    case QueueRepo.query(@leader, [name]) do
      {:ok, %{rows: [[node]]}} -> node
      _ -> nil
    end
  end
end
