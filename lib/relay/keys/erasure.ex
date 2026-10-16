defmodule Relay.Keys.Erasure do
  @moduledoc """
  Crypto-shredding. Personal data is erased by destroying the data key it is encrypted under; rows stay, unreadable. A subject erasure destroys the subject's data keys of every class without a legal retention obligation, restricts those with one (kept, never used in normal processing), soft-deletes the recipient, clears its blind indexes and cancels its pending deliveries, all in one tenant-scoped transaction with its audit record and erasure log row. An active legal hold on the tenant or the recipient stops it with `:held` and changes nothing. Tenant keys are destroyed the same way: a receipt day key seven days after its day, data and wrapping keys only for a closed tenant.

  Which classes carry an obligation comes from the retention data set (Access Appendix C by region and sector); the caller passes it.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Audit], exports: []

  alias Relay.Keys.Erasure.Store

  @subject_classes ~w(recipient_profile notification_content delivery_record commercial_consent commercial_message preference)

  @type scope :: %{tenant_id: Relay.Id.t(), environment: String.t()}
  @type actor :: %{
          required(:kind) => String.t(),
          required(:ref) => String.t(),
          required(:on_behalf_of) => String.t(),
          optional(:access_record_ref) => String.t() | nil
        }
  @type plan :: %{destroy: [String.t()], restrict: [String.t()]}

  # OP-18
  # C-86
  @doc "Retention classes that have a data key per subject."
  @spec subject_classes() :: [String.t(), ...]
  def subject_classes, do: @subject_classes

  @doc "Splits the subject classes into those to destroy and those to restrict, given the classes under a legal retention obligation."
  @spec plan([String.t()]) :: {:ok, plan()} | {:error, Relay.Error.t()}
  def plan(obligated) when is_list(obligated) do
    case Enum.reject(obligated, &(&1 in @subject_classes)) do
      [] ->
        restrict = Enum.filter(@subject_classes, &(&1 in obligated))
        {:ok, %{destroy: @subject_classes -- restrict, restrict: restrict}}

      unknown ->
        {:error,
         Relay.Error.new(:invalid_argument, "unknown retention class", %{classes: unknown})}
    end
  end

  # MKT-13
  # OP-17
  # OP-24
  # C-86
  @doc """
  Erases a subject. Returns `{:ok, :erased | :already_erased | :held | :not_found, cancelled_deliveries}`.
  """
  @spec erase_subject(scope(), Relay.Id.t(), String.t(), [String.t()], actor()) ::
          {:ok, :erased | :already_erased | :held | :not_found, non_neg_integer()}
          | {:error, Relay.Error.t()}
  def erase_subject(scope, <<_::128>> = recipient_id, request_ref, obligated, actor)
      when is_binary(request_ref) and request_ref != "" do
    with {:ok, plan} <- plan(obligated) do
      digest =
        record_digest(scope, "subject.erased", actor, "recipient", recipient_id, request_ref)

      Store.subject_erase(scope, recipient_id, request_ref, plan, digest, actor)
    end
  end

  # OP-17
  # OP-26
  @doc "Destroys a tenant key. Returns `{:ok, :destroyed | :already_destroyed | :held | :not_allowed}`."
  @spec destroy_tenant_key(scope(), Relay.Id.t(), String.t(), actor()) ::
          {:ok, :destroyed | :already_destroyed | :held | :not_allowed}
          | {:error, Relay.Error.t()}
  def destroy_tenant_key(scope, <<_::128>> = key_id, reason, actor)
      when reason in ["retention_end", "tenant_closed", "erasure"] do
    digest = record_digest(scope, "tenant_key.destroyed", actor, "tenant_key", key_id, reason)
    Store.tenant_key_destroy(scope, key_id, reason, digest, actor)
  end

  # OP-17
  @doc "Returns true if a receipt day key may be destroyed on `today`: seven days after its day."
  @spec receipt_key_due?(Date.t(), Date.t()) :: boolean()
  def receipt_key_due?(%Date{} = valid_day, %Date{} = today), do: Date.diff(today, valid_day) >= 7

  defp record_digest(scope, action, actor, target_type, target_id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      action: action,
      actor_kind: actor.kind,
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of,
      access_record_ref: Map.get(actor, :access_record_ref),
      target_type: target_type,
      target_id: Relay.Id.to_string(target_id),
      reason: reason
    })
  end
end
