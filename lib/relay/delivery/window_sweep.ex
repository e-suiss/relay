defmodule Relay.Delivery.WindowSweep do
  @moduledoc """
  The DLR window sweep (DS-18, INV-5). Every five minutes on the `maintenance` queue it lists the scopes that have an accepted delivery older than the shortest window (by identifiers only) and moves each scope's due deliveries through their windows: `sent` becomes `unknown_pending` after the short window and `unknown` after the long one, each step a `delivery.unknown_pending` or `delivery.unknown` ledger entry written by Relay. The windows are the scope's resolved `delivery_windows` (`Relay.DeliveryWindows.resolve/2`); time is business time, so a step of a `test` scope's virtual clock moves its deliveries at once (`run_due/1` is a due provider of the virtual clock). The sweep never resends and never starts a fallback (INV-9, DS-21).

  Telemetry: `[:relay, :delivery, :window]` with `count: 1` per moved delivery, with its `channel`, `provider` and `stage` (`unknown_pending` or `unknown`).
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Delivery, Relay.Datasets], exports: []

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 240_000

  require Logger

  alias Relay.Datasets
  alias Relay.DeliveryWindows

  @dataset "delivery_windows"
  @batch 500
  @scopes 100

  # DS-18
  # INV-5
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = sweep()
    :ok
  end

  # DS-18
  @doc "Moves the due deliveries of every scope that may have one and returns the number of scopes swept."
  @spec sweep(pos_integer()) :: non_neg_integer()
  def sweep(limit \\ @scopes) do
    limit
    |> Relay.Delivery.window_scopes()
    |> Enum.count(fn {tenant_id, environment} ->
      with {:ok, scope} <- Relay.Scope.new(tenant_id, environment),
           :ok <- run_due(scope) do
        true
      else
        _failed -> false
      end
    end)
  end

  # DS-18
  # DS-23
  # T-24
  @doc "Moves the due deliveries of one scope through their windows, batch by batch."
  @spec run_due(Relay.Scope.t()) :: :ok | {:error, term()}
  def run_due(%Relay.Scope{} = scope) do
    case windows(scope) do
      {:ok, []} -> :ok
      {:ok, windows} -> advance(scope, windows)
      {:error, reason} -> {:error, reason}
    end
  end

  # DS-18
  # DS-50
  @doc "The resolved windows of a scope: the installation version adjusted by the scope's own version; none without an installation version."
  @spec windows(Relay.Scope.t()) :: {:ok, [DeliveryWindows.window()]} | {:error, term()}
  def windows(%Relay.Scope{} = scope) do
    with {:ok, installation} <- Datasets.active(Datasets.installation_scope(), @dataset),
         {:ok, tenant} <- Datasets.active(scope, @dataset) do
      case installation do
        nil -> {:ok, []}
        version -> {:ok, DeliveryWindows.resolve(version.content, tenant && tenant.content)}
      end
    end
  end

  defp advance(scope, windows) do
    case Relay.Delivery.advance_windows(scope, windows, @batch) do
      {:ok, moved} ->
        Enum.each(moved, &report/1)
        if length(moved) == @batch, do: advance(scope, windows), else: :ok

      {:error, reason} ->
        Logger.error("delivery window sweep failed", environment: scope.environment)
        {:error, reason}
    end
  end

  defp report(%{channel: channel, provider: provider, window_stage: stage}) do
    :telemetry.execute([:relay, :delivery, :window], %{count: 1}, %{
      channel: channel,
      provider: provider,
      stage: if(stage == 2, do: "unknown", else: "unknown_pending")
    })
  end
end
