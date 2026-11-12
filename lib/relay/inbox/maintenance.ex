defmodule Relay.Inbox.Maintenance do
  @moduledoc """
  The `inbox_maintenance` singleton task, run once a day (OP-42, IN-18, IN-44, OP-22). A sweep walks every tenant environment (found through the maintenance escape hatch, by identifiers only) and, in each one, first reconciles the counters of the recipients whose counters or items changed in the 24 hours before the sweep started, fixing only the drifted ones (`Relay.Inbox.reconcile_changed/4`), then ends the retention of the items whose retention period is over (`Relay.Inbox.retire_due/2`). Each step is one batch in the scope's own transaction; the position is saved after every step, so a new leader continues the sweep. A finished sweep starts again a day after it started.

  Telemetry: `[:relay, :inbox, :counter_drift]` with `source: :nightly` for the drifted counters each batch fixed, and `[:relay, :inbox, :maintenance]` at the end of a sweep with the counts of checked and repaired recipients and retired items.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Inbox, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Scope

  @day_ms 24 * 60 * 60_000
  @step_ms 1_000
  @batch 200

  @type state :: %{optional(String.t()) => term()}

  # OP-42
  # IN-18
  # IN-44
  @impl Relay.Platform.Leadership
  @doc "Runs one step of the sweep: one batch of one scope, or waits until a day since the last sweep started has passed."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: saved}) do
    now = Relay.Clock.utc_now()
    state = saved || %{}

    case wait_ms(state, now) do
      0 ->
        with {:ok, scopes} <- EscapeHatch.tenant_scopes(),
             do: step(start(state, now), scopes)

      wait ->
        {:ok, state, wait}
    end
  end

  @doc "Returns how long to wait before the next sweep starts: zero while a sweep runs or once a day has passed since the last one started."
  @spec wait_ms(state(), DateTime.t()) :: non_neg_integer()
  def wait_ms(%{"sweep" => %{}}, _now), do: 0

  def wait_ms(%{"started_at" => started}, now) do
    {:ok, started, _} = DateTime.from_iso8601(started)
    max(@day_ms - DateTime.diff(now, started, :millisecond), 0)
  end

  def wait_ms(_state, _now), do: 0

  defp start(%{"sweep" => %{}} = state, _now), do: state

  defp start(state, now) do
    Map.put(state, "sweep", %{
      "started_at" => DateTime.to_iso8601(now),
      "since" => now |> DateTime.add(-@day_ms, :millisecond) |> DateTime.to_iso8601(),
      "scope" => nil,
      "phase" => "reconcile",
      "after" => nil,
      "checked" => 0,
      "repaired" => 0,
      "retired" => 0
    })
  end

  defp key(%{tenant_id: tenant, environment: environment}),
    do: {Relay.Id.to_string(tenant), environment}

  defp key(%{"tenant_id" => tenant, "environment" => environment}), do: {tenant, environment}

  defp current(scopes, nil), do: List.first(scopes)

  defp current(scopes, saved) do
    saved_key = key(saved)
    Enum.find(scopes, &(key(&1) >= saved_key))
  end

  defp next(scopes, scope) do
    scope_key = key(scope)
    Enum.find(scopes, &(key(&1) > scope_key))
  end

  defp step(%{"sweep" => sweep} = state, scopes) do
    case current(scopes, sweep["scope"]) do
      nil ->
        finish(state)

      target ->
        same? = sweep["scope"] != nil and key(target) == key(sweep["scope"])
        sweep = if same?, do: sweep, else: %{sweep | "phase" => "reconcile", "after" => nil}
        work(%{state | "sweep" => %{sweep | "scope" => text(target)}}, scopes, target)
    end
  end

  defp work(%{"sweep" => %{"phase" => "reconcile"} = sweep} = state, scopes, target) do
    scope = Scope.new!(target.tenant_id, target.environment)
    {:ok, since, _} = DateTime.from_iso8601(sweep["since"])

    case Relay.Inbox.reconcile_changed(scope, since, parse(sweep["after"]), @batch) do
      {:ok, %{checked: checked, repaired: repaired, last: last}} ->
        sweep = %{
          sweep
          | "checked" => sweep["checked"] + checked,
            "repaired" => sweep["repaired"] + repaired
        }

        sweep =
          if checked == @batch,
            do: %{sweep | "after" => Relay.Id.to_string(last)},
            else: %{sweep | "phase" => "retire", "after" => nil}

        {:ok, %{state | "sweep" => sweep}, @step_ms}

      {:error, error} ->
        skip(state, scopes, target, error)
    end
  end

  defp work(%{"sweep" => sweep} = state, scopes, target) do
    scope = Scope.new!(target.tenant_id, target.environment)

    case Relay.Inbox.retire_due(scope, @batch) do
      {:ok, retired} ->
        sweep = %{sweep | "retired" => sweep["retired"] + retired}
        state = %{state | "sweep" => sweep}
        if retired == @batch, do: {:ok, state, @step_ms}, else: advance(state, scopes, target)

      {:error, error} ->
        skip(state, scopes, target, error)
    end
  end

  defp skip(state, scopes, target, %Relay.Error{code: :not_found}),
    do: advance(state, scopes, target)

  defp skip(_state, _scopes, _target, %Relay.Error{} = error), do: {:error, error}

  defp skip(_state, _scopes, _target, _other),
    do: {:error, Relay.Error.new(:database_error, "inbox maintenance failed")}

  defp advance(%{"sweep" => sweep} = state, scopes, target) do
    case next(scopes, target) do
      nil ->
        finish(state)

      found ->
        sweep = %{sweep | "scope" => text(found), "phase" => "reconcile", "after" => nil}
        {:ok, %{state | "sweep" => sweep}, @step_ms}
    end
  end

  defp finish(%{"sweep" => sweep}) do
    :telemetry.execute(
      [:relay, :inbox, :maintenance],
      %{checked: sweep["checked"], repaired: sweep["repaired"], retired: sweep["retired"]},
      %{}
    )

    {:ok,
     %{
       "started_at" => sweep["started_at"],
       "last_sweep" => Map.drop(sweep, ["scope", "after", "phase", "since"])
     }, @day_ms}
  end

  defp text(%{tenant_id: tenant, environment: environment}),
    do: %{"tenant_id" => Relay.Id.to_string(tenant), "environment" => environment}

  defp parse(nil), do: nil

  defp parse(text) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end
end
