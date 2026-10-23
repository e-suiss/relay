defmodule Relay.Keys.Erasure do
  @moduledoc """
  Crypto-shredding. Personal data is erased by destroying the data key it is encrypted under; rows stay, unreadable. A subject erasure destroys the subject's data keys of every class without a legal retention obligation, restricts those with one (kept, never used in normal processing), soft-deletes the recipient, clears its blind indexes and cancels its pending deliveries, all in one tenant-scoped transaction with its audit record and erasure log row. An active legal hold on the tenant or the recipient stops it with `:held` and changes nothing. Tenant keys are destroyed the same way: a receipt day key seven days after its day, data and wrapping keys only for a closed tenant.

  Which classes carry an obligation is never taken from the caller: inside the erasure transaction it is derived from the active `retention_periods` data set (Access Appendix C) for the tenant's region and sector, and a subject class with a period of more than zero days is restricted. A tenant whose region and sector have no row in the data set, or an installation without an active version, is refused and nothing changes. After a key is destroyed or restricted every node drops it from its key cache (`Relay.Keys.Eviction`).
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Audit, Relay.Datasets, Relay.Keys.Eviction],
    exports: []

  alias Relay.Keys.Erasure.Store

  @subject_classes ~w(recipient_profile notification_content delivery_record commercial_consent commercial_message preference)
  @dataset "retention_periods"

  @type scope :: Relay.Scope.t()
  @type actor :: Relay.Actor.t()
  @type plan :: %{destroy: [String.t()], restrict: [String.t()]}

  # OP-18
  # C-86
  @doc "Retention classes that have a data key per subject."
  @spec subject_classes() :: [String.t(), ...]
  def subject_classes, do: @subject_classes

  # TN-67 (2)
  # OP-18
  # OP-69 (3)
  @doc "Splits the subject classes into those to destroy and those to restrict for a region and sector, from the content of a `retention_periods` version: a subject class with a period of more than zero days is under a legal retention obligation. A region and sector without any row is refused."
  @spec plan(map(), String.t(), String.t()) :: {:ok, plan()} | {:error, Relay.Error.t()}
  def plan(%{"periods" => periods}, region, sector)
      when is_list(periods) and is_binary(region) and is_binary(sector) do
    rows = Enum.filter(periods, &(&1["region"] == region and &1["sector"] == sector))

    obligated =
      for %{"retention_class" => class, "days" => days} <- rows,
          class in @subject_classes and is_integer(days) and days > 0,
          do: class

    if rows == [] do
      {:error,
       Relay.Error.new(
         :retention_rule_missing,
         "no retention periods for the region and sector",
         %{
           region: region,
           sector: sector
         }
       )}
    else
      restrict = Enum.filter(@subject_classes, &(&1 in obligated))
      {:ok, %{destroy: @subject_classes -- restrict, restrict: restrict}}
    end
  end

  def plan(_content, _region, _sector),
    do: {:error, Relay.Error.new(:invalid_dataset, "not a retention_periods version")}

  # MKT-13
  # OP-17
  # OP-24
  # C-86
  # TN-67 (2)
  @doc """
  Erases a subject; the classes to restrict come from the active `retention_periods` data set for the tenant's region and sector (`plan/3`). Returns `{:ok, :erased | :already_erased | :held | :not_found, cancelled_deliveries}`.
  """
  @spec erase_subject(scope(), Relay.Id.t(), String.t(), actor()) ::
          {:ok, :erased | :already_erased | :held | :not_found, non_neg_integer()}
          | {:error, Relay.Error.t()}
  def erase_subject(scope, <<_::128>> = recipient_id, request_ref, actor)
      when is_binary(request_ref) and request_ref != "" do
    digest =
      record_digest(scope, "subject.erased", actor, "recipient", recipient_id, request_ref)

    result = Store.subject_erase(scope, recipient_id, request_ref, &tenant_plan/1, digest, actor)
    evict(result, :erased)
    result
  end

  defp tenant_plan(%{"region" => region, "sector" => sector}) do
    case Relay.Datasets.decide(
           Relay.Datasets.installation_scope(),
           @dataset,
           &plan(&1, region, sector)
         ) do
      {:ok, {plan, _ref}} -> plan
      {:error, error} -> {:error, error}
    end
  end

  # OP-17
  # OP-26
  @doc "Destroys a tenant key. Returns `{:ok, :destroyed | :already_destroyed | :held | :not_allowed | :not_found}`."
  @spec destroy_tenant_key(scope(), Relay.Id.t(), String.t(), actor()) ::
          {:ok, :destroyed | :already_destroyed | :held | :not_allowed | :not_found}
          | {:error, Relay.Error.t()}
  def destroy_tenant_key(scope, <<_::128>> = key_id, reason, actor)
      when reason in ["retention_end", "tenant_closed", "erasure"] do
    digest = record_digest(scope, "tenant_key.destroyed", actor, "tenant_key", key_id, reason)

    result = Store.tenant_key_destroy(scope, key_id, reason, digest, actor)
    evict(result, :destroyed)
    result
  end

  # OP-16
  @doc "Destroys a subject data key whose retention period ended. Returns `{:ok, :retired | :already_destroyed | :held | :not_found}`."
  @spec retire_subject_key(scope(), Relay.Id.t(), actor()) ::
          {:ok, :retired | :already_destroyed | :held | :not_found} | {:error, Relay.Error.t()}
  def retire_subject_key(scope, <<_::128>> = key_id, actor) do
    digest =
      record_digest(scope, "subject_key.retired", actor, "subject_key", key_id, "retention_end")

    result = Store.subject_key_retire(scope, key_id, digest, actor)
    evict(result, :retired)
    result
  end

  # OP-17
  @doc "Returns true if a receipt day key may be destroyed on `today`: seven days after its day."
  @spec receipt_key_due?(Date.t(), Date.t()) :: boolean()
  def receipt_key_due?(%Date{} = valid_day, %Date{} = today), do: Date.diff(today, valid_day) >= 7

  # TN-66 (2)
  defp evict(result, changed) when elem(result, 0) == :ok and elem(result, 1) == changed,
    do: Relay.Keys.Eviction.notify()

  defp evict(_result, _changed), do: :ok

  defp record_digest(scope, action, actor, target_type, target_id, reason) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: target_type,
      target_id: Relay.Id.to_string(target_id),
      reason: reason
    })
  end
end
