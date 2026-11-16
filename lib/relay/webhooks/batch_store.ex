defmodule Relay.Webhooks.BatchStore do
  @moduledoc """
  Data access of the object store batches (WH-21). A batch row is written only through the `relay_fn.webhook_batch_*` functions, which take the time of the caller's clock, and is never deleted. Every function runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  @type id :: Relay.Id.t()

  @closed ~w(closed unchanged)a
  @added ~w(added not_found lock_lost batch_closed)a
  @claimed ~w(claimed not_found finished not_due locked tenant_inactive endpoint_archived
              endpoint_paused endpoint_disabled empty)a
  @finished ~w(finished not_found)a

  # WH-21
  @doc "Reads the open batch of an endpoint and locks it, and the endpoint's batching, until the transaction ends; `nil` when the endpoint has no open batch."
  @spec open_lock(id()) :: map() | nil
  def open_lock(endpoint_id) do
    case Repo.call!("relay_fn.webhook_batch_lock", [endpoint_id]) do
      [row] -> row
      [] -> nil
    end
  end

  # WH-21
  @doc "Closes an open batch, so that it takes no more events."
  @spec close(id(), DateTime.t()) :: atom()
  def close(batch_id, now) do
    [row] = Repo.call!("relay_fn.webhook_batch_close", [batch_id, now])
    Repo.code!(row["webhook_batch_close"], @closed)
  end

  # WH-21
  @doc "Puts a claimed message into a batch, which is created open with `closes_at` when it does not exist yet, counts its `bytes` and gives the message back to wait for the batch; `close?` closes the batch with this event."
  @spec add(id(), id(), id(), DateTime.t(), pos_integer(), boolean(), DateTime.t()) :: atom()
  def add(message_id, token, batch_id, closes_at, bytes, close?, now) do
    params = [message_id, token, batch_id, closes_at, bytes, close?, now]
    [row] = Repo.call!("relay_fn.webhook_batch_add", params)
    Repo.code!(row["webhook_batch_add"], @added)
  end

  # WH-21
  # WH-37
  @doc "Claims a batch for one write until `locked_until`: an open batch that is due is closed, and every member that is not terminal is locked. Returns the result and the claimed messages. The members of a batch whose endpoint is paused or disabled are held, those of an archived endpoint end, and the batch fails."
  @spec claim(id(), id(), DateTime.t(), DateTime.t()) :: {atom(), [id()]}
  def claim(batch_id, token, locked_until, now) do
    rows = Repo.call!("relay_fn.webhook_batch_claim", [batch_id, token, locked_until, now])

    case rows do
      [%{"result" => "claimed"} | _rest] -> {:claimed, Enum.map(rows, & &1["message_id"])}
      [%{"result" => result}] -> {Repo.code!(result, @claimed), []}
    end
  end

  # WH-21
  @doc "Ends a closed batch as `written`, with the name and the digest of its object, or as `failed`."
  @spec finish(id(), String.t(), String.t() | nil, binary() | nil, DateTime.t()) :: atom()
  def finish(batch_id, state, object_key, object_digest, now) do
    params = [batch_id, state, object_key, object_digest, now]
    [row] = Repo.call!("relay_fn.webhook_batch_finish", params)
    Repo.code!(row["webhook_batch_finish"], @finished)
  end

  # WH-21
  @doc "Reads a batch, or `nil`."
  @spec batch(id()) :: map() | nil
  def batch(id) do
    one(
      """
      SELECT b.id, b.endpoint_id, b.state, b.opened_at, b.closes_at, b.closed_at, b.event_count,
        b.byte_count, b.object_key, b.object_digest, b.attempt_count, b.written_at
      FROM relay.webhook_batches b WHERE b.id = $1
      """,
      [id]
    )
  end

  # WH-21
  @doc "The batch a message waits in: the open or closed batch it is a member of, or `nil`."
  @spec membership(id()) :: map() | nil
  def membership(message_id) do
    one(
      """
      SELECT b.id, b.state, b.closes_at FROM relay.webhook_messages m
      JOIN relay.webhook_batches b ON b.tenant_id = m.tenant_id
        AND b.environment = m.environment AND b.id = m.batch_id
      WHERE m.id = $1 AND b.state IN ('open', 'closed')
      """,
      [message_id]
    )
  end

  # WH-21
  # WH-32 (4)
  @doc "The batches of the scope that were to be written at or before `before` and are neither written nor failed, oldest first, at most `limit`."
  @spec overdue(DateTime.t(), pos_integer()) :: [map()]
  def overdue(before, limit) do
    %{rows: rows, columns: columns} =
      Repo.scoped_query!(
        """
        SELECT b.id, b.state FROM relay.webhook_batches b
        WHERE b.state IN ('open', 'closed') AND b.closes_at <= $1
        ORDER BY b.closes_at LIMIT $2
        """,
        [before, limit]
      )

    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  defp one(sql, params) do
    case Repo.scoped_query!(sql, params) do
      %{rows: [row], columns: columns} -> columns |> Enum.zip(row) |> Map.new()
      %{rows: []} -> nil
    end
  end
end
