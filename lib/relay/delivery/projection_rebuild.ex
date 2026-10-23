defmodule Relay.Delivery.ProjectionRebuild do
  @moduledoc """
  The `projection_rebuild` singleton task, the weekly "rebuild from the ledger" check: every delivery projection is recomputed from its ledger and compared with the stored one, and no difference may exist (OP-3). A sweep walks every tenant environment (found through the maintenance escape hatch, by identifiers only) and checks its deliveries in identifier order, one batch per step in the scope's own read-only transaction; the cursor is saved after every step, so a new leader continues the sweep. A finished sweep starts again a week after it finished.

  Telemetry: `[:relay, :projection, :difference]` for each differing delivery (also logged with the delivery id and the differing columns) and `[:relay, :projection, :rebuilt]` at the end of a sweep with the counts of checked and differing deliveries.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Delivery, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Scope

  @week_ms 7 * 24 * 60 * 60_000
  @step_ms 1_000
  @batch 500

  @type state :: %{optional(String.t()) => term()}

  # OP-3
  # OP-42
  @impl Relay.Platform.Leadership
  @doc "Runs one step of the sweep: one batch of one scope, or waits until the week since the last sweep has passed."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: saved}) do
    now = Relay.Clock.utc_now()
    state = saved || %{}

    case wait_ms(state, now) do
      0 ->
        with {:ok, scopes} <- EscapeHatch.tenant_scopes(),
             do: step(start(state, now), scopes, now)

      wait ->
        {:ok, state, wait}
    end
  end

  @doc "Returns how long to wait before the next sweep starts: zero while a sweep is running or once a week has passed since the last one finished."
  @spec wait_ms(state(), DateTime.t()) :: non_neg_integer()
  def wait_ms(%{"sweep" => %{}}, _now), do: 0

  def wait_ms(%{"finished_at" => finished}, now) do
    {:ok, finished, _} = DateTime.from_iso8601(finished)
    max(@week_ms - DateTime.diff(now, finished, :millisecond), 0)
  end

  def wait_ms(_state, _now), do: 0

  defp start(%{"sweep" => %{}} = state, _now), do: state

  defp start(state, now) do
    Map.put(state, "sweep", %{
      "started_at" => DateTime.to_iso8601(now),
      "scope" => nil,
      "after" => nil,
      "checked" => 0,
      "differing" => 0
    })
  end

  @doc "Returns the scope a sweep works on: the saved one if it still exists, otherwise the first scope after it."
  @spec current([map()], map() | nil) :: map() | nil
  def current(scopes, nil), do: List.first(scopes)

  def current(scopes, %{"tenant_id" => tenant, "environment" => environment}) do
    key = {tenant, environment}
    Enum.find(scopes, &(key(&1) >= key))
  end

  @doc "Returns the scope after `scope` in sweep order, or nil at the end."
  @spec next([map()], map()) :: map() | nil
  def next(scopes, scope) do
    key = key(scope)
    Enum.find(scopes, &(key(&1) > key))
  end

  defp key(%{tenant_id: tenant, environment: environment}),
    do: {Relay.Id.to_string(tenant), environment}

  defp key(%{"tenant_id" => tenant, "environment" => environment}), do: {tenant, environment}

  defp step(%{"sweep" => sweep} = state, scopes, now) do
    case current(scopes, sweep["scope"]) do
      nil ->
        finish(state, now)

      target ->
        same? = sweep["scope"] != nil and key(target) == key(sweep["scope"])
        after_id = if same?, do: parse(sweep["after"]), else: nil
        check(state, scopes, target, after_id, now)
    end
  end

  defp check(%{"sweep" => sweep} = state, scopes, target, after_id, now) do
    scope = Scope.new!(target.tenant_id, target.environment)

    case Relay.Delivery.check_projections(scope, after_id, @batch) do
      {:ok, %{checked: checked, differing: differing}} ->
        Enum.each(differing, &report(scope, &1))

        sweep = %{
          sweep
          | "checked" => sweep["checked"] + length(checked),
            "differing" => sweep["differing"] + length(differing)
        }

        advance(%{state | "sweep" => sweep}, scopes, target, checked, now)

      {:error, %Relay.Error{code: :not_found}} ->
        advance(state, scopes, target, [], now)

      {:error, %Relay.Error{} = error} ->
        {:error, error}

      {:error, _other} ->
        {:error, Relay.Error.new(:database_error, "projection check failed")}
    end
  end

  defp advance(%{"sweep" => sweep} = state, scopes, target, checked, now) do
    cond do
      length(checked) == @batch ->
        sweep = %{
          sweep
          | "scope" => text(target),
            "after" => Relay.Id.to_string(List.last(checked))
        }

        {:ok, %{state | "sweep" => sweep}, @step_ms}

      next = next(scopes, target) ->
        {:ok, %{state | "sweep" => %{sweep | "scope" => text(next), "after" => nil}}, @step_ms}

      true ->
        finish(state, now)
    end
  end

  defp finish(%{"sweep" => sweep}, now) do
    :telemetry.execute(
      [:relay, :projection, :rebuilt],
      %{checked: sweep["checked"], differing: sweep["differing"]},
      %{}
    )

    if sweep["differing"] > 0,
      do: Logger.error("projection rebuild found differences", differing: sweep["differing"])

    {:ok,
     %{
       "finished_at" => DateTime.to_iso8601(now),
       "last_sweep" => Map.drop(sweep, ["scope", "after"])
     }, @week_ms}
  end

  defp report(scope, {delivery_id, columns}) do
    :telemetry.execute([:relay, :projection, :difference], %{count: 1}, %{
      environment: scope.environment
    })

    Logger.error("delivery projection differs from its ledger",
      delivery_id: Relay.Id.to_string(delivery_id),
      columns: Enum.map_join(columns, ",", &elem(&1, 0))
    )
  end

  defp text(%{tenant_id: tenant, environment: environment}),
    do: %{"tenant_id" => Relay.Id.to_string(tenant), "environment" => environment}

  defp parse(nil), do: nil

  defp parse(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end
end
