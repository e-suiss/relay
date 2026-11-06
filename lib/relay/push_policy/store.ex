defmodule Relay.PushPolicy.Store do
  @moduledoc """
  Data access of the tenant push policy: the `push.critical` setting, the warning of the high priority monitor and its audit records. Every function except `in_scope/2` runs inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # CH-20
  @doc "Reads the tenant-level `push.critical` setting row (`value`, `updated_at`), or `nil`."
  @spec opening() :: map() | nil
  def opening do
    %Postgrex.Result{columns: columns, rows: rows} =
      Repo.scoped_query!(
        """
        SELECT tenant_id, environment, value, updated_at FROM relay.settings
        WHERE subtenant_id IS NULL AND key = 'push.critical'
        """,
        []
      )

    case rows do
      [row] -> columns |> Enum.zip(row) |> Map.new()
      [] -> nil
    end
  end

  # CH-22
  @doc "Appends the `push_priority.threshold_reached` operations event and its audit record."
  @spec warn(map(), map(), binary(), Relay.Actor.t()) :: :ok
  def warn(payload, record, digest, %Relay.Actor{} = actor) do
    [row] =
      Repo.call!("relay_fn.outbox_append", [
        Relay.Id.generate(),
        "push_priority.threshold_reached",
        "push_priority:tenant",
        payload,
        nil
      ])

    Repo.code!(row["result"], [:appended])
    audit(record, digest, actor)
  end

  # TN-47
  @doc "Appends one audit record in the established scope."
  @spec audit(map(), binary(), Relay.Actor.t()) :: :ok
  def audit(record, digest, %Relay.Actor{} = actor) do
    [kind, ref, on_behalf_of, access_record] = Relay.Actor.params(actor)

    [_row] =
      Repo.call!("relay_fn.audit_append", [
        Relay.Id.generate(),
        record.action,
        kind,
        ref,
        on_behalf_of,
        access_record,
        record.target_type,
        record.target_id,
        record.reason,
        nil,
        nil,
        digest
      ])

    :ok
  end
end
