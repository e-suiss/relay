defmodule Relay.TenantLifecycle do
  @moduledoc """
  The end of a tenant's life and the keys it holds: the tenant's own key in the region's key store (OP-85, `Relay.Tenancy.KeyCustody`) and the two-step closure with its full export and crypto-shred (OP-86, OP-26, `Relay.TenantLifecycle.Closure`). Every action is an installation operator action, audited in the tenant's `live` environment; this module computes the audit record digests.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Audit,
      Relay.Delivery,
      Relay.Keys.Erasure,
      Relay.Parquet,
      Relay.Subscribers,
      Relay.Tenancy
    ],
    exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.TenantLifecycle.Closure

  # OP-85
  # TN-21
  @doc "Sets or changes a tenant's own key and wraps the tenant's keys under it; see `Relay.Tenancy.KeyCustody.set/4`."
  @spec set_key_custody(Relay.Id.t(), String.t(), Actor.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def set_key_custody(<<_::128>> = tenant_id, key_ref, %Actor{} = actor)
      when is_binary(key_ref) do
    live = Scope.new!(tenant_id, :live)
    target = Relay.Id.to_string(tenant_id)
    record_digest = digest(live, "tenant.key_custody_changed", "tenant", target, key_ref, actor)

    Relay.Tenancy.set_key_custody(tenant_id, key_ref, record_digest, actor)
  end

  # OP-85
  @doc "Reads a tenant's own key reference; see `Relay.Tenancy.KeyCustody.show/1`."
  @spec key_custody(Relay.Id.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def key_custody(<<_::128>> = tenant_id), do: Relay.Tenancy.key_custody(tenant_id)

  # OP-86
  @doc "Requests the closure of a tenant; see `Relay.TenantLifecycle.Closure.request/5`."
  @spec request_closure(Relay.Id.t(), map(), Actor.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def request_closure(tenant_id, attrs, %Actor{} = actor, step_up_ref),
    do: Closure.request(tenant_id, attrs, actor, step_up_ref, digester(actor))

  # OP-86
  @doc "Reads the closure of a tenant with its download links; see `Relay.TenantLifecycle.Closure.show/1`."
  @spec closure(Relay.Id.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate closure(tenant_id), to: Closure, as: :show

  # OP-86
  @doc "Records the tenant's explicit confirmation; see `Relay.TenantLifecycle.Closure.confirm/4`."
  @spec confirm_closure(Relay.Id.t(), String.t(), Actor.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def confirm_closure(tenant_id, confirmation_ref, %Actor{} = actor),
    do: Closure.confirm(tenant_id, confirmation_ref, actor, digester(actor))

  # OP-86
  # OP-26
  @doc "Destroys the keys of a closed tenant; see `Relay.TenantLifecycle.Closure.shred/4`."
  @spec shred(Relay.Id.t(), Actor.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def shred(tenant_id, %Actor{} = actor, step_up_ref),
    do: Closure.shred(tenant_id, actor, step_up_ref, digester(actor))

  # OP-86
  @doc "Writes the full export of a closure; run by `Relay.TenantLifecycle.ClosureJob`."
  @spec export_closure(Relay.Id.t(), Relay.Id.t()) ::
          {:ok, :ready | :not_exporting} | {:error, term()}
  def export_closure(tenant_id, closure_id),
    do: Closure.run_export(tenant_id, closure_id, digester(Closure.system_actor()))

  # OP-86
  @doc "The export formats this installation writes."
  @spec closure_formats() :: [String.t(), ...]
  defdelegate closure_formats(), to: Closure, as: :formats

  defp digester(actor) do
    fn scope, action, target_type, target_id, reason ->
      digest(scope, action, target_type, target_id, reason, actor)
    end
  end

  defp digest(scope, action, target_type, target_id, reason, actor) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: action,
      actor_kind: Atom.to_string(actor.kind),
      actor_ref: actor.ref,
      on_behalf_of_ref: actor.on_behalf_of_ref,
      access_record_ref: actor.access_record_ref,
      target_type: target_type,
      target_id: target_id,
      reason: reason
    })
  end
end
