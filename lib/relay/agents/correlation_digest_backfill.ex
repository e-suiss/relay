defmodule Relay.Agents.CorrelationDigestBackfill do
  @moduledoc """
  The `correlation_digest_backfill` singleton task (AG-65): a one-time pass that replaces the correlation keys stored in clear before AG-65 on waitpoints and buffered early events by their keyed digests. The key store is not reachable from SQL, so the pass runs in the application: it walks every tenant environment (found through the maintenance escape hatch, by identifiers only) in identifier order, one batch per step (`Relay.Agents.backfill_correlation_digests/2`), and saves the scope it works on after every step, so a new leader continues. A converted row no longer holds a key, so a repeated step is harmless. Once every scope is done it stays idle.

  Unmatched event records (`waitpoint_unmatched_events`) are append-only (INV-6) and keep the keys they were written with; every record written since AG-65 holds the digest.

  Telemetry: `[:relay, :agents, :correlation_digest_backfill]` at the end of the pass with the counts of scanned and converted rows.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Agents, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Scope

  @batch 200
  @step_ms 1_000
  @idle_ms 24 * 60 * 60_000

  # AG-65
  @impl Relay.Platform.Leadership
  @doc "Runs one step of the pass: one batch of one scope, or nothing once the pass has finished."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: %{"finished_at" => _at} = state}), do: {:ok, state, @idle_ms}

  def run(%{state: saved}) do
    start = %{"scope" => nil, "scanned" => 0, "updated" => 0}
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
      nil -> finish(state)
      target -> backfill(state, scopes, target)
    end
  end

  defp backfill(state, scopes, target) do
    scope = Scope.new!(target.tenant_id, target.environment)

    case Relay.Agents.backfill_correlation_digests(scope, @batch) do
      {:ok, %{scanned: scanned, updated: updated}} ->
        state = %{
          state
          | "scanned" => state["scanned"] + scanned,
            "updated" => state["updated"] + updated
        }

        advance(state, scopes, target, scanned)

      {:error, %Relay.Error{code: :not_found}} ->
        advance(state, scopes, target, 0)

      {:error, %Relay.Error{} = error} ->
        {:error, error}

      {:error, _other} ->
        {:error, Relay.Error.new(:database_error, "correlation digest backfill failed")}
    end
  end

  defp advance(state, scopes, target, scanned) do
    cond do
      scanned > 0 ->
        {:ok, %{state | "scope" => text(target)}, @step_ms}

      next = next(scopes, target) ->
        {:ok, %{state | "scope" => text(next)}, @step_ms}

      true ->
        finish(state)
    end
  end

  defp finish(state) do
    :telemetry.execute(
      [:relay, :agents, :correlation_digest_backfill],
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
end
