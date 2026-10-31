defmodule Relay.Platform.VirtualClock do
  @moduledoc """
  Advancing the virtual clock of a tenant's `test` environment (TN-8, X-27). The offset only grows, by at most 366 days per step and ten years in total, and every step is audited as `virtual_clock.advanced` with the record digest the caller computed. A `live` scope gets `:not_test_environment` and nothing is written; the database refuses a `live` row as well.

  In the transaction that advances the clock a `Relay.Platform.VirtualClock.Tick` job is queued; once the step commits it runs the due providers configured under `:due`, `{module, function, args}` entries called with the scope first, so that waitpoint deadlines, heartbeats and later stages' timers that fell due in business time run at once.
  """

  alias Relay.Platform.VirtualClock.Tick
  alias Relay.Platform.VirtualClockStore

  @type result ::
          {:advanced, non_neg_integer(), DateTime.t()} | :not_test_environment | :invalid_step

  # TN-8
  # X-27
  # T-57 (3)
  @doc "Advances the virtual clock of a `test` scope by `by_ms` milliseconds and queues the tick that runs what fell due."
  @spec advance(Relay.Scope.t(), integer(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, result()} | {:error, Relay.Error.t()}
  def advance(%Relay.Scope{} = scope, by_ms, <<_::256>> = record_digest, %Relay.Actor{} = actor)
      when is_integer(by_ms) do
    scope
    |> VirtualClockStore.in_scope(fn _status ->
      case VirtualClockStore.advance(by_ms, record_digest, actor) do
        {:advanced, _offset, _now} = advanced ->
          {:ok, _job} = Oban.insert(Tick.new(Relay.Scope.to_job_args(scope)))
          advanced

        other ->
          other
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, %Relay.Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, Relay.Error.new(:database_error, "virtual clock not advanced")}
    end
  end

  # TN-8
  # X-27
  @doc "Advances the virtual clock inside the caller's scoped transaction of `scope`, the transaction of an idempotent request, and queues the tick in it."
  @spec advance_here(Relay.Scope.t(), integer(), <<_::256>>, Relay.Actor.t()) :: result()
  def advance_here(%Relay.Scope{} = scope, by_ms, <<_::256>> = record_digest, actor)
      when is_integer(by_ms) do
    case VirtualClockStore.advance(by_ms, record_digest, actor) do
      {:advanced, _offset, _now} = advanced ->
        {:ok, _job} = Oban.insert(Tick.new(Relay.Scope.to_job_args(scope)))
        advanced

      other ->
        other
    end
  end

  # X-27
  @doc "Returns the scope's virtual offset and business time, or `:not_test_environment` in `live`."
  @spec get(Relay.Scope.t()) ::
          {:ok, {:ok, non_neg_integer(), DateTime.t()} | :not_test_environment}
          | {:error, term()}
  def get(%Relay.Scope{} = scope),
    do: VirtualClockStore.in_scope(scope, fn _status -> VirtualClockStore.get() end)

  @doc "The configured due providers, `{module, function, args}` entries."
  @spec due_providers() :: [{module(), atom(), list()}]
  def due_providers,
    do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:due, [])
end
