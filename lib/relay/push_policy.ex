defmodule Relay.PushPolicy do
  @moduledoc """
  Tenant push policy at send time: the `critical` opening of a tenant (CH-20, TN-23), the audit record of every critical delivery, and the high priority send ratio monitor (CH-22). The channel step calls these functions outside its transactions.

  * The opening is stored by the installation operator with step-up (`Relay.Operators.Admin.set_critical_interruption/5`) as the tenant's `push.critical` setting in its `live` environment and applies to both environments. Without it `critical` is never opened, whatever the request asks.
  * Every delivery that goes out at the `critical` level is audited as `push_critical.used`, with the delivery as the target and the template key as the reason.
  * Every push send is counted per tenant and environment in two sliding counters over 24 hours (all sends, and the sends at high priority: `apns-priority` 10 or FCM `HIGH`). When at least `min_volume` sends were counted and more than `ratio_bp` of them went out at high priority, the tenant is warned with a `push_priority.threshold_reached` operations event and the audit record of the same name, at most once per window. The values are the POLICY DEFAULT of `threshold/0`. A counter that cannot be read leaves the send alone: monitoring never holds a delivery.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Audit, Relay.Platform], exports: []

  alias Relay.PushPolicy.Store
  alias Relay.Scope

  @window_ms 86_400_000
  @ratio_bp 2_000
  @min_volume 1_000
  @actor_ref "relay"

  @type opening :: %{
          enabled: boolean(),
          templates: [String.t()],
          entitlements: [%{platform: String.t(), reference: String.t()}],
          updated_at: DateTime.t() | nil
        }

  @type critical_use :: %{
          required(:delivery_id) => Relay.Id.t(),
          required(:template_key) => String.t() | nil
        }

  # CH-22
  @doc "The POLICY DEFAULT of the high priority monitor: the share in basis points above which a tenant is warned, the least number of sends it is judged on and the sliding window."
  @spec threshold() :: %{
          ratio_bp: pos_integer(),
          min_volume: pos_integer(),
          window_ms: pos_integer()
        }
  def threshold, do: %{ratio_bp: @ratio_bp, min_volume: @min_volume, window_ms: @window_ms}

  # CH-20
  # TN-23
  @doc "Reads the tenant's `critical` opening from its `live` environment; a tenant without one is closed."
  @spec critical_opening(Scope.t()) :: {:ok, opening()} | {:error, term()}
  def critical_opening(%Scope{tenant_id: tenant_id}) do
    live = Scope.new!(tenant_id, :live)

    with {:ok, row} <- Store.in_scope(live, fn _status -> Store.opening() end),
         do: {:ok, opening(row)}
  end

  # CH-20
  # CH-66
  @doc "Returns true when the opening is enabled and declares `template_key` critical in advance."
  @spec critical_template?(opening(), String.t() | nil) :: boolean()
  def critical_template?(%{enabled: true, templates: templates}, key) when is_binary(key),
    do: key in templates

  def critical_template?(_opening, _key), do: false

  @doc "The opening of a stored `push.critical` setting row, or of none."
  @spec opening(map() | nil) :: opening()
  def opening(%{"value" => %{"templates" => templates} = value} = row) when is_list(templates) do
    %{
      enabled: true,
      templates: templates,
      entitlements: entitlements(value["entitlements"]),
      updated_at: row["updated_at"]
    }
  end

  def opening(row) do
    %{enabled: false, templates: [], entitlements: [], updated_at: row && row["updated_at"]}
  end

  defp entitlements(list) when is_list(list) do
    for %{"platform" => platform, "reference" => reference} <- list,
        do: %{platform: platform, reference: reference}
  end

  defp entitlements(_none), do: []

  # CH-20
  # TN-47
  @doc "Audits a delivery sent at the `critical` level as `push_critical.used`."
  @spec record_critical_use(Scope.t(), critical_use()) :: :ok | {:error, term()}
  def record_critical_use(%Scope{} = scope, %{delivery_id: delivery_id} = attrs) do
    record = %{
      action: "push_critical.used",
      target_type: "delivery",
      target_id: Relay.Id.to_string(delivery_id),
      reason: Map.get(attrs, :template_key)
    }

    audit(scope, record)
  end

  # CH-22
  @doc "Counts one push send of the tenant, at high priority when `high?`; returns `:warned` when this send crossed the threshold and the tenant was warned, `:counted` otherwise, and an error when a counter could not be read."
  @spec record_priority(Scope.t(), boolean()) :: {:ok, :counted | :warned} | {:error, term()}
  def record_priority(%Scope{} = scope, high?) when is_boolean(high?) do
    with {:ok, total} <- counter(scope, "push_priority:total", :incr, 1),
         {:ok, high} <- counter(scope, "push_priority:high", :incr, if(high?, do: 1, else: 0)) do
      if over?(high, total), do: warn(scope, high, total), else: {:ok, :counted}
    end
  end

  # CH-22
  @doc "Returns true when `high` of `total` sends are over the threshold on enough volume."
  @spec over?(non_neg_integer(), non_neg_integer()) :: boolean()
  def over?(high, total) when is_integer(high) and is_integer(total),
    do: total >= @min_volume and high * 10_000 > @ratio_bp * total

  defp warn(scope, high, total) do
    with {:ok, 0} <- counter(scope, "push_priority:warned", :read, 0),
         {:ok, _marked} <- counter(scope, "push_priority:warned", :incr, 1),
         :ok <- warned(scope, high, total) do
      {:ok, :warned}
    else
      {:ok, _already} -> {:ok, :counted}
      {:error, error} -> {:error, error}
    end
  end

  defp warned(scope, high, total) do
    ratio = div(high * 10_000, total)

    payload = %{
      "window" => "PT24H",
      "high" => high,
      "total" => total,
      "ratio_bp" => ratio,
      "threshold_bp" => @ratio_bp
    }

    record = %{
      action: "push_priority.threshold_reached",
      target_type: "tenant",
      target_id: Relay.Id.to_string(scope.tenant_id),
      reason: "ratio_bp " <> Integer.to_string(ratio)
    }

    digest = digest(scope, record)

    case Store.in_scope(scope, fn _status -> Store.warn(payload, record, digest, actor()) end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp counter(scope, key, op, by),
    do: Relay.Platform.rate_counter(scope, key, @window_ms, op, by)

  defp audit(scope, record) do
    digest = digest(scope, record)

    case Store.in_scope(scope, fn _status -> Store.audit(record, digest, actor()) end) do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp digest(scope, record) do
    Relay.Audit.record_digest(%{
      tenant_id: scope.tenant_id,
      environment: Relay.Environment.dump(scope.environment),
      action: record.action,
      actor_kind: "system",
      actor_ref: @actor_ref,
      on_behalf_of_ref: @actor_ref,
      access_record_ref: nil,
      target_type: record.target_type,
      target_id: record.target_id,
      reason: record.reason
    })
  end

  defp actor do
    {:ok, actor} = Relay.Actor.new(:system, @actor_ref, @actor_ref)
    actor
  end
end
