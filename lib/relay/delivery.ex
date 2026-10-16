defmodule Relay.Delivery do
  @moduledoc """
  The delivery ledger, delivery state and reconciliation. Other contexts use only the functions of this module.

  Every function takes the scope and runs in its own scoped transaction (`Relay.Repo.in_scope/3`).
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Delivery.Ledger
  alias Relay.Delivery.Store
  alias Relay.Scope

  @type result(value) :: {:ok, value} | {:error, term()}

  # C-32
  @doc "Builds a ledger entry; see `Relay.Delivery.Ledger.new/1`."
  @spec ledger_entry(map() | keyword()) :: {:ok, Ledger.t()} | {:error, Relay.Error.t()}
  defdelegate ledger_entry(attrs), to: Ledger, as: :new

  # OP-3
  # OP-4
  @doc "Appends a ledger entry; see `Relay.Delivery.Ledger.append/1`."
  @spec append_ledger(Scope.t(), Ledger.t()) ::
          result({Ledger.result(), Ledger.rank() | nil, non_neg_integer() | nil})
  def append_ledger(scope, %Ledger{} = entry),
    do: Store.in_scope(scope, fn _status -> Ledger.append(entry) end)

  @doc "Cancels a delivery."
  @spec cancel_delivery(Scope.t(), Relay.Id.t(), String.t(), binary(), Actor.t()) ::
          result(atom())
  def cancel_delivery(scope, delivery_id, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.delivery_cancel(delivery_id, rule_id, digest, actor)
    end)
  end

  @doc "Cancels a notification and its pending deliveries."
  @spec cancel_notification(Scope.t(), Relay.Id.t(), String.t(), binary(), Actor.t()) ::
          result({atom(), non_neg_integer() | nil})
  def cancel_notification(scope, notification_id, rule_id, digest, actor) do
    Store.in_scope(scope, fn _status ->
      Store.notification_cancel(notification_id, rule_id, digest, actor)
    end)
  end

  # C-31
  @doc "Opens the next attempt of a delivery."
  @spec open_attempt(Scope.t(), map()) :: result({atom(), non_neg_integer() | nil})
  def open_attempt(scope, attrs),
    do: Store.in_scope(scope, fn _status -> Store.attempt_open(attrs) end)

  # INV-55
  @doc "Marks an attempt started in its own transaction, before the provider call."
  @spec start_attempt(Scope.t(), Relay.Id.t(), pos_integer()) :: result(atom())
  def start_attempt(scope, delivery_id, attempt_no),
    do: Store.in_scope(scope, fn _status -> Store.attempt_start(delivery_id, attempt_no) end)

  @doc "Finishes an attempt."
  @spec finish_attempt(Scope.t(), map()) :: result({atom(), atom() | nil})
  def finish_attempt(scope, attrs),
    do: Store.in_scope(scope, fn _status -> Store.attempt_finish(attrs) end)

  # C-88
  @doc "Appends a usage record for a closed UTC day."
  @spec record_usage(Scope.t(), map()) :: result(atom())
  def record_usage(scope, attrs),
    do: Store.in_scope(scope, fn _status -> Store.usage_record_append(attrs) end)

  # C-2
  @doc "Rebuilds a delivery projection from the ledger and returns the differences."
  @spec rebuild_projection(Scope.t(), Relay.Id.t()) :: result([{String.t(), term(), term()}])
  def rebuild_projection(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.projection_rebuild(delivery_id) end)

  @doc "Reads a notification; another tenant's or environment's notification is not found (TN-15)."
  @spec notification(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def notification(scope, id), do: Store.in_scope(scope, fn _status -> Store.notification(id) end)

  @doc "Reads a delivery; another tenant's or environment's delivery is not found (TN-15)."
  @spec delivery(Scope.t(), Relay.Id.t()) :: result(map() | nil)
  def delivery(scope, id), do: Store.in_scope(scope, fn _status -> Store.delivery(id) end)

  @doc "Reads the ledger of a delivery."
  @spec ledger(Scope.t(), Relay.Id.t()) :: result([map()])
  def ledger(scope, delivery_id),
    do: Store.in_scope(scope, fn _status -> Store.ledger(delivery_id) end)
end
