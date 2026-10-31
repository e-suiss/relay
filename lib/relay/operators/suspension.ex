defmodule Relay.Operators.Suspension do
  @moduledoc """
  Suspension of a tenant or of one of its subtenants by the installation operator (TN-10, TN-71, INV-42). The record lives in the tenant's `live` environment and applies to both environments. A suspension on abuse, security or legal grounds takes effect at once with a reasoned notice due within the policy's hours; on other grounds it takes effect no earlier than the policy's notice days. The appeal window follows the effective time. The values come from the active `suspension_policy` data set, whose legal basis awaits legal approval and blocks a release until approved; without an active version no suspension is recorded.

  An effective suspension sets the tenant (or subtenant) `suspended`; every entry point rejects new work from then on (`auth_tenant_suspended`). Lifting sets it `active` again; paused work is not resumed by itself. Both are audited (`tenant.suspended`, `tenant.resumed`).
  """

  alias Relay.Actor
  alias Relay.Operators.Store
  alias Relay.Scope

  @grounds ~w(abuse security legal other)
  @policy "suspension_policy"

  @type attrs :: %{
          required(:ground) => String.t(),
          required(:reason) => String.t(),
          optional(:subtenant_id) => Relay.Id.t() | nil,
          optional(:effective_at) => DateTime.t() | nil
        }

  # TN-71
  @doc "Reads the active suspension policy: `notice_days`, `immediate_notice_hours` and `appeal_days`."
  @spec policy() :: {:ok, map()} | {:error, Relay.Error.t()}
  def policy do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), @policy) do
      {:ok, %{content: %{"notice_days" => _} = content}} ->
        {:ok, content}

      {:ok, nil} ->
        {:error, Relay.Error.new(:service_unavailable, "no suspension policy is active")}

      {:error, _error} ->
        {:error, Relay.Error.new(:service_unavailable, "the suspension policy is unavailable")}
    end
  end

  # TN-10
  # TN-71
  @doc "Records a suspension in the tenant's `live` scope and returns the stored record."
  @spec suspend(Relay.Id.t(), attrs(), Actor.t(), String.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def suspend(tenant_id, %{ground: ground, reason: reason} = attrs, %Actor{} = actor, step_up_ref)
      when ground in @grounds do
    scope = Scope.new!(tenant_id, :live)
    id = Relay.Id.generate()

    with {:ok, policy} <- policy(),
         :ok <- effective_rule(ground, Map.get(attrs, :effective_at), policy) do
      digest =
        Relay.Operators.record_digest(
          scope,
          "tenant.suspended",
          actor,
          "tenant_suspension",
          Relay.Id.to_string(id),
          reason
        )

      record = %{
        id: id,
        subtenant_id: Map.get(attrs, :subtenant_id),
        ground: ground,
        reason: reason,
        effective_at: Map.get(attrs, :effective_at),
        step_up_ref: step_up_ref
      }

      scope
      |> Store.in_scope(fn _status -> record(record, digest, actor) end)
      |> outcome()
    end
  end

  defp record(record, digest, actor) do
    case Store.suspension_record(record, digest, actor) do
      {result, id} when result in [:scheduled, :effective] -> {:ok, Store.suspension_get(id)}
      {result, _id} -> {:error, result}
    end
  end

  defp effective_rule("other", %DateTime{} = at, policy) do
    earliest = DateTime.add(Relay.Clock.utc_now(), policy["notice_days"] * 86_400, :second)

    if DateTime.compare(at, earliest) == :lt,
      do: {:error, field("/effective_at", "too_short", "the notice period is too short")},
      else: :ok
  end

  defp effective_rule("other", nil, _policy),
    do: {:error, field("/effective_at", "required", "ground other needs effective_at")}

  defp effective_rule(_ground, nil, _policy), do: :ok

  defp effective_rule(_ground, _at, _policy),
    do: {:error, field("/effective_at", "not_allowed", "this ground takes effect at once")}

  # TN-22
  @doc "Lifts the open suspension of the tenant, or of one subtenant, and returns the stored record."
  @spec resume(Relay.Id.t(), Relay.Id.t() | nil, String.t(), Actor.t(), String.t()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def resume(tenant_id, subtenant_id, reason, %Actor{} = actor, step_up_ref) do
    scope = Scope.new!(tenant_id, :live)

    scope
    |> Store.in_scope(fn _status ->
      case Store.suspension_open(subtenant_id) do
        nil -> {:error, :not_suspended}
        open -> lift(scope, open["id"], reason, actor, step_up_ref)
      end
    end)
    |> outcome()
  end

  defp lift(scope, id, reason, actor, step_up_ref) do
    target = Relay.Id.to_string(id)

    digest =
      Relay.Operators.record_digest(
        scope,
        "tenant.resumed",
        actor,
        "tenant_suspension",
        target,
        reason
      )

    case Store.suspension_lift(id, reason, step_up_ref, digest, actor) do
      result when result in [:lifted, :cancelled] -> {:ok, Store.suspension_get(id)}
      result -> {:error, result}
    end
  end

  # TN-71
  @doc "Puts the scheduled suspensions that are due into effect; returns how many took effect."
  @spec activate_due(pos_integer()) :: non_neg_integer()
  def activate_due(limit \\ 100) do
    for %{"tenant_id" => tenant_id, "suspension_id" => id} <- Store.suspensions_due(limit),
        {:ok, :effective} <-
          [
            Store.in_scope(Scope.new!(tenant_id, :live), fn _ -> Store.suspension_activate(id) end)
          ],
        reduce: 0 do
      total -> total + 1
    end
  end

  @doc "Lists the recent suspensions of a tenant."
  @spec list(Relay.Id.t()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def list(tenant_id) do
    case Store.in_scope(Scope.new!(tenant_id, :live), fn _status -> Store.suspensions() end) do
      {:ok, rows} -> {:ok, rows}
      {:error, %Relay.Error{code: :not_found}} -> {:error, not_found()}
      {:error, error} -> {:error, error}
    end
  end

  defp outcome({:ok, {:ok, row}}), do: {:ok, row}
  defp outcome({:ok, {:error, :already_suspended}}), do: conflict("already suspended")
  defp outcome({:ok, {:error, :not_suspended}}), do: conflict("there is no open suspension")
  defp outcome({:ok, {:error, :already_ended}}), do: conflict("the suspension has ended")

  defp outcome({:ok, {:error, :subtenant_not_found}}),
    do: {:error, field("/subtenant_id", "not_found", "no such subtenant")}

  defp outcome({:ok, {:error, code}}) when code in [:notice_too_short, :effective_not_allowed],
    do: {:error, field("/effective_at", "invalid_format", "effective_at is not allowed")}

  defp outcome({:ok, {:error, :not_found}}), do: {:error, not_found()}
  defp outcome({:error, %Relay.Error{code: :not_found}}), do: {:error, not_found()}
  defp outcome({:error, %Relay.Error{} = error}), do: {:error, error}

  defp conflict(detail), do: {:error, Relay.Error.new(:resource_conflict, detail)}
  defp not_found, do: Relay.Error.new(:tenant_not_found, "no such tenant")

  defp field(pointer, code, detail) do
    Relay.Error.new(:validation_failed, detail, %{
      errors: [%{pointer: pointer, code: code, detail: detail}]
    })
  end
end
