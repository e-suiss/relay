defmodule Relay.Delivery.FailureActorBackfill do
  @moduledoc """
  The `failure_actor_backfill` singleton task: a one-time pass that fills the failure source (`failure_actor`, DS-4 (3)) of deliveries whose projection was written before the source was kept, from their own ledger, so the weekly rebuild check finds no difference on them (OP-3). It walks every tenant environment (found through the maintenance escape hatch, by identifiers only) in identifier order, one batch per step in the scope's own transaction, and saves its cursor after every step, so a new leader continues. Nothing is deleted; only an empty source is written. Once every scope is done it stays idle.

  Telemetry: `[:relay, :delivery, :failure_actor_backfill]` at the end of the pass with the counts of scanned and updated deliveries.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Delivery, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Scope

  @batch 500
  @step_ms 1_000
  @idle_ms 24 * 60 * 60_000

  # DS-4 (3)
  # OP-3
  @impl Relay.Platform.Leadership
  @doc "Runs one step of the pass: one batch of one scope, or nothing once the pass has finished."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: %{"finished_at" => _at} = state}), do: {:ok, state, @idle_ms}

  def run(%{state: saved}) do
    start = %{"scope" => nil, "after" => nil, "scanned" => 0, "updated" => 0}
    state = Map.merge(start, saved || %{})

    case EscapeHatch.tenant_scopes() do
      {:ok, scopes} -> step(state, scopes)
      {:error, error} -> {:error, error}
    end
  end

  @doc "Returns the scope a pass works on: the saved one if it still exists, otherwise the first scope after it."
  @spec current([map()], map() | nil) :: map() | nil
  def current(scopes, nil), do: List.first(scopes)

  def current(scopes, %{"tenant_id" => tenant, "environment" => environment}) do
    key = {tenant, environment}
    Enum.find(scopes, &(key(&1) >= key))
  end

  @doc "Returns the scope after `scope` in pass order, or nil at the end."
  @spec next([map()], map()) :: map() | nil
  def next(scopes, scope) do
    key = key(scope)
    Enum.find(scopes, &(key(&1) > key))
  end

  defp key(%{tenant_id: tenant, environment: environment}),
    do: {Relay.Id.to_string(tenant), environment}

  defp key(%{"tenant_id" => tenant, "environment" => environment}), do: {tenant, environment}

  defp step(state, scopes) do
    case current(scopes, state["scope"]) do
      nil ->
        finish(state)

      target ->
        same? = state["scope"] != nil and key(target) == key(state["scope"])
        after_id = if same?, do: parse(state["after"]), else: nil
        backfill(state, scopes, target, after_id)
    end
  end

  defp backfill(state, scopes, target, after_id) do
    scope = Scope.new!(target.tenant_id, target.environment)

    case Relay.Delivery.backfill_failure_actors(scope, after_id, @batch) do
      {:ok, %{scanned: scanned, updated: updated, last_id: last_id}} ->
        state = %{
          state
          | "scanned" => state["scanned"] + scanned,
            "updated" => state["updated"] + updated
        }

        advance(state, scopes, target, scanned, last_id)

      {:error, %Relay.Error{code: :not_found}} ->
        advance(state, scopes, target, 0, nil)

      {:error, %Relay.Error{} = error} ->
        {:error, error}

      {:error, _other} ->
        {:error, Relay.Error.new(:database_error, "failure source backfill failed")}
    end
  end

  defp advance(state, scopes, target, scanned, last_id) do
    cond do
      scanned == @batch ->
        cursor = %{state | "scope" => text(target), "after" => Relay.Id.to_string(last_id)}
        {:ok, cursor, @step_ms}

      next = next(scopes, target) ->
        {:ok, %{state | "scope" => text(next), "after" => nil}, @step_ms}

      true ->
        finish(state)
    end
  end

  defp finish(state) do
    :telemetry.execute(
      [:relay, :delivery, :failure_actor_backfill],
      %{scanned: state["scanned"], updated: state["updated"]},
      %{}
    )

    {:ok,
     %{
       "finished_at" => DateTime.to_iso8601(Relay.Clock.utc_now()),
       "scanned" => state["scanned"],
       "updated" => state["updated"]
     }, @idle_ms}
  end

  defp text(%{tenant_id: tenant, environment: environment}),
    do: %{"tenant_id" => Relay.Id.to_string(tenant), "environment" => environment}

  defp parse(nil), do: nil

  defp parse(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end
end
