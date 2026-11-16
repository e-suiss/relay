defmodule Relay.Webhooks.Maintenance do
  @moduledoc """
  The `webhook_maintenance` singleton task, run once a day (WH-6, WH-30, WH-52, TN-63). A sweep walks every tenant environment (found through the maintenance escape hatch, by identifiers only) and, in each one, retires the signing keys whose rotation overlap ended, destroys the key store objects of retired keys so that they can never sign again, and erases the stored answers and event payloads whose retention ended, one batch a step: the contract's periods or the shorter ones of the tenant's `webhook.retention` setting. Rows are never deleted. The position is saved after every step, so a new leader continues the sweep. A finished sweep starts again a day after it started.

  Telemetry: `[:relay, :webhooks, :maintenance]` at the end of a sweep with the counts of retired and destroyed keys and erased answers and payloads.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Webhooks, Relay.Platform.Maintenance, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  alias Relay.Platform.Maintenance.EscapeHatch
  alias Relay.Scope

  @day_ms 24 * 60 * 60_000
  @step_ms 1_000
  @batch 500
  @counters ~w(keys_retired keys_destroyed responses payloads)

  @type state :: %{optional(String.t()) => term()}

  # WH-30
  # WH-6
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
    sweep = Map.new(@counters, &{&1, 0})
    sweep = Map.merge(sweep, %{"started_at" => DateTime.to_iso8601(now), "scope" => nil})
    Map.put(state, "sweep", sweep)
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
      nil -> finish(state)
      target -> work(%{state | "sweep" => %{sweep | "scope" => text(target)}}, scopes, target)
    end
  end

  defp work(%{"sweep" => sweep} = state, scopes, target) do
    scope = Scope.new!(target.tenant_id, target.environment)

    with {:ok, retired} <- Relay.Webhooks.expire_keys(scope),
         {:ok, destroyed} <- Relay.Webhooks.destroy_retired_keys(scope),
         {:ok, erased} <- Relay.Webhooks.retire_due(scope, @batch) do
      sweep =
        sweep
        |> Map.update!("keys_retired", &(&1 + retired))
        |> Map.update!("keys_destroyed", &(&1 + destroyed))
        |> Map.update!("responses", &(&1 + erased.responses))
        |> Map.update!("payloads", &(&1 + erased.payloads))

      state = %{state | "sweep" => sweep}
      more? = erased.responses == @batch or erased.payloads == @batch
      if more?, do: {:ok, state, @step_ms}, else: advance(state, scopes, target)
    else
      {:error, error} -> skip(state, scopes, target, error)
    end
  end

  defp skip(state, scopes, target, %Relay.Error{code: :not_found}),
    do: advance(state, scopes, target)

  defp skip(_state, _scopes, _target, %Relay.Error{} = error), do: {:error, error}

  defp skip(_state, _scopes, _target, _other),
    do: {:error, Relay.Error.new(:database_error, "webhook maintenance failed")}

  defp advance(%{"sweep" => sweep} = state, scopes, target) do
    case next(scopes, target) do
      nil -> finish(state)
      found -> {:ok, %{state | "sweep" => %{sweep | "scope" => text(found)}}, @step_ms}
    end
  end

  defp finish(%{"sweep" => sweep}) do
    counts = %{
      keys_retired: sweep["keys_retired"],
      keys_destroyed: sweep["keys_destroyed"],
      responses: sweep["responses"],
      payloads: sweep["payloads"]
    }

    :telemetry.execute([:relay, :webhooks, :maintenance], counts, %{})

    {:ok, %{"started_at" => sweep["started_at"], "last_sweep" => Map.delete(sweep, "scope")},
     @day_ms}
  end

  defp text(%{tenant_id: tenant, environment: environment}),
    do: %{"tenant_id" => Relay.Id.to_string(tenant), "environment" => environment}
end
