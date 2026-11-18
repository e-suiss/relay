defmodule Relay.Migration.Rollout do
  @moduledoc """
  The staged rollout of a tenant environment (OP-53, OP-80, OP-95): its configuration, read through the node cache (`Relay.Migration.RolloutCache`), the routing of a request's recipients (`Relay.Migration.Routing`), the ramp rule checked on every replacement (`Relay.Migration.Ramp`), and the emergency stop, one call that routes everything to the system being replaced and opens an incident record. Pinned recipients are kept as digests (`Relay.Migration.Bucket.digest/2`), never as external identifiers. Every write signals the other nodes after it commits.
  """

  alias Relay.Actor
  alias Relay.Migration.Bucket
  alias Relay.Migration.Ramp
  alias Relay.Migration.RolloutCache
  alias Relay.Migration.Routing
  alias Relay.Migration.Store
  alias Relay.Scope

  # OP-53
  # OP-95
  @doc "The routing configuration of a scope, `nil` when none is set; read through the node cache."
  @spec config(Scope.t()) :: {:ok, Routing.config() | nil} | {:error, term()}
  def config(%Scope{} = scope) do
    case RolloutCache.lookup(scope) do
      {:ok, config} ->
        {:ok, config}

      :miss ->
        with {:ok, row} <- Store.in_scope(scope, fn _status -> Store.rollout() end) do
          config = routing(row)
          :ok = RolloutCache.put(scope, config)
          {:ok, config}
        end
    end
  end

  # OP-53
  # OP-95
  @doc "The external identifiers of a request's recipients that the rollout sends to the system being replaced."
  @spec legacy(Scope.t(), String.t() | nil, [String.t()]) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def legacy(%Scope{} = scope, category, external_ids) when is_list(external_ids) do
    with {:ok, config} <- config(scope) do
      legacy =
        for id <- external_ids,
            Routing.route(config, scope.tenant_id, category, id) == :legacy,
            into: MapSet.new(),
            do: id

      {:ok, legacy}
    end
  end

  # OP-95
  @doc "The stored configuration of a scope, `nil` when none is set."
  @spec read(Scope.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(%Scope{} = scope), do: Store.in_scope(scope, fn _status -> Store.rollout() end)

  # OP-53
  # OP-95
  @doc "Replaces the configuration after checking the ramp rule; returns the stored configuration, `{:error, {:ramp, errors}}` for a step the rule refuses or `{:error, :version_conflict}` when `generation` is not the one stored."
  @spec replace(Scope.t(), map(), Actor.t()) :: {:ok, map()} | {:error, term()}
  def replace(%Scope{} = scope, body, %Actor{} = actor) do
    expected = body["generation"]
    digest = digest(scope, "rollout.updated")

    work = fn _status ->
      steps = steps(Store.rollout())
      shares = body["basis_points"] || %{}

      with {:ok, steps} <- ramp(steps, shares) do
        config = %{
          relay_list: digests(scope, body["relay_list"]),
          legacy_list: digests(scope, body["legacy_list"]),
          enabled_categories: Enum.sort(body["enabled_categories"] || []),
          basis_points: shares,
          steps: steps
        }

        case Store.rollout_put(config, expected, digest, actor) do
          {:updated, _generation} -> {:ok, Store.rollout()}
          {:version_conflict, _generation} -> {:error, :version_conflict}
        end
      end
    end

    Store.in_scope(scope, work) |> unwrap() |> signalled()
  end

  # OP-53
  # OP-95
  @doc "The emergency stop: routes every request of the scope to the system being replaced and opens an incident record, both audited; a stopped rollout stays as it is."
  @spec stop(Scope.t(), String.t(), Actor.t()) :: {:ok, map()} | {:error, term()}
  def stop(%Scope{} = scope, reason, %Actor{} = actor) when is_binary(reason) do
    digest = digest(scope, "rollout.emergency_stopped")
    incident = digest(scope, "incident.opened")

    work = fn _status ->
      case Store.rollout_stop(reason, incident, digest, actor) do
        {:stopped, _generation} ->
          :telemetry.execute([:relay, :rollout, :emergency_stop], %{count: 1})

        {:already_stopped, _generation} ->
          :ok
      end

      {:ok, Store.rollout()}
    end

    Store.in_scope(scope, work) |> unwrap() |> signalled()
  end

  # OP-53
  @doc "Releases the emergency stop; `{:error, :not_stopped}` when the rollout is not stopped."
  @spec release(Scope.t(), String.t(), Actor.t()) :: {:ok, map()} | {:error, term()}
  def release(%Scope{} = scope, reason, %Actor{} = actor) when is_binary(reason) do
    digest = digest(scope, "rollout.emergency_released")

    work = fn _status ->
      case Store.rollout_release(reason, digest, actor) do
        {:released, _generation} -> {:ok, Store.rollout()}
        {:not_stopped, _generation} -> {:error, :not_stopped}
      end
    end

    Store.in_scope(scope, work) |> unwrap() |> signalled()
  end

  # OP-95
  @doc "The routing form of a stored configuration."
  @spec routing(map() | nil) :: Routing.config() | nil
  def routing(nil), do: nil
  def routing(%{"configured" => false, "emergency_stop" => false}), do: nil

  def routing(row) do
    %{
      emergency_stop: row["emergency_stop"] == true,
      relay_list: MapSet.new(row["relay_list"] || []),
      legacy_list: MapSet.new(row["legacy_list"] || []),
      enabled_categories: MapSet.new(row["enabled_categories"] || []),
      basis_points: row["basis_points"] || %{}
    }
  end

  defp ramp(steps, shares) do
    case Ramp.check(steps, shares, Relay.Clock.utc_now()) do
      {:ok, steps} -> {:ok, steps}
      {:error, errors} -> {:error, {:ramp, errors}}
    end
  end

  defp steps(nil), do: %{}
  defp steps(row), do: row["steps"] || %{}

  defp digests(scope, ids) when is_list(ids),
    do: ids |> Enum.map(&Bucket.digest(scope.tenant_id, &1)) |> Enum.uniq() |> Enum.sort()

  defp digests(_scope, _ids), do: []

  defp digest(scope, action) do
    environment = Relay.Environment.dump(scope.environment)
    record = [action, {:bytes, scope.tenant_id}, environment]
    :crypto.hash(:sha256, Relay.Canonical.encode!(record))
  end

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp signalled({:ok, row} = result) do
    :ok = RolloutCache.forget()
    _ = Relay.Platform.publish_signal(RolloutCache.topic(), (row && row["generation"]) || 0)
    result
  end

  defp signalled(error), do: error
end
