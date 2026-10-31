defmodule Relay.Access.EventStore do
  @moduledoc """
  Data access of the Access event receipts (`relay.access_event_receipts`, S-69). A receipt and the job that processes it commit in one transaction before the delivery is acknowledged; a repeated `webhook-id` is a duplicate and queues nothing. Receipts are installation records, reached through `relay_ops` escape hatches.
  """

  alias Relay.Repo

  @states [:processed, :rejected, :deferred]

  @type receipt :: %{
          id: Relay.Id.t(),
          webhook_id: String.t(),
          event_type: String.t(),
          access_tenant_id: String.t() | nil,
          payload: map(),
          state: String.t()
        }

  # E-36
  # T-56
  @doc "Records a receipt and, when it is new, queues `job` (built from the receipt identifier) in the same transaction."
  @spec record(map(), (Relay.Id.t() -> Ecto.Changeset.t())) ::
          {:ok, :recorded | :duplicate} | {:error, term()}
  def record(attrs, job) do
    Repo.transaction(fn ->
      [row] =
        Repo.call_unscoped!(:access_event_intake, "relay_ops.access_event_receipt_record", [
          attrs.id,
          attrs.webhook_id,
          attrs.event_type,
          attrs.access_tenant_id,
          attrs.payload,
          attrs.body_digest,
          attrs.traceparent
        ])

      case Repo.code!(row["access_event_receipt_record"], [:recorded, :duplicate]) do
        :recorded -> enqueue(job.(attrs.id))
        :duplicate -> :duplicate
      end
    end)
  end

  defp enqueue(changeset) do
    case Oban.insert(changeset) do
      {:ok, _job} -> :recorded
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # E-36
  @doc "Reads a receipt."
  @spec read(Relay.Id.t()) :: receipt() | nil
  def read(id) do
    case Repo.call_unscoped!(:access_event_intake, "relay_ops.access_event_receipt_read", [id]) do
      [row] ->
        %{
          id: id,
          webhook_id: row["webhook_id"],
          event_type: row["event_type"],
          access_tenant_id: row["access_tenant_id"],
          payload: row["payload"],
          state: row["state"]
        }

      [] ->
        nil
    end
  end

  # E-36
  @doc "Marks a receipt processed, rejected or deferred, with a reason."
  @spec mark(Relay.Id.t(), :processed | :rejected | :deferred, String.t() | nil) ::
          :marked | :already_final | :not_found
  def mark(id, state, reason) when state in @states do
    [row] =
      Repo.call_unscoped!(:access_event_intake, "relay_ops.access_event_receipt_mark", [
        id,
        Atom.to_string(state),
        reason
      ])

    Repo.code!(row["access_event_receipt_mark"], [:marked, :already_final, :not_found])
  end

  # E-36
  @doc "The deferred receipts of an Access tenant or with a reason, oldest first."
  @spec deferred(String.t() | nil, String.t() | nil, pos_integer()) :: [Relay.Id.t()]
  def deferred(access_tenant_id, reason, limit) do
    rows =
      Repo.call_unscoped!(:access_event_intake, "relay_ops.access_event_receipts_deferred", [
        access_tenant_id,
        reason,
        limit
      ])

    Enum.map(rows, & &1["id"])
  end

  # E-36
  @doc "Queues jobs outside any transaction."
  @spec enqueue_all([Ecto.Changeset.t()]) :: :ok
  def enqueue_all([]), do: :ok

  def enqueue_all(changesets) do
    _ = Oban.insert_all(changesets)
    :ok
  end
end
