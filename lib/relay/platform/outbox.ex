defmodule Relay.Platform.Outbox do
  @moduledoc """
  The outbox reader and dispatcher. For each scope with pending rows it claims a batch in a scoped transaction, inserts the jobs the handler derives from each event, marks the batch dispatched and commits; only then does it publish one signal per stream with the stream's latest sequence number (INV-53). The transaction makes no network call (INV-55); a lost signal costs latency, never an event.

  A handler is a function from an outbox event to the `Oban.Job` changesets that deliver it; the default handler derives none.
  """

  alias Relay.Platform.OutboxStore
  alias Relay.Platform.Signal
  alias Relay.Platform.Valkey.Key
  alias Relay.Scope

  require Logger

  @type handler :: (OutboxStore.event() -> [Ecto.Changeset.t()])
  @type option ::
          {:batch, pos_integer()}
          | {:scopes, pos_integer()}
          | {:handler, handler()}
          | {:publish, (Signal.topic(), non_neg_integer() -> :ok | {:error, term()})}

  @batch 100
  @scopes 50

  # INV-2
  # INV-53
  # OP-5
  # OP-7
  @doc "Dispatches one batch of a scope's pending outbox rows and returns how many were dispatched."
  @spec dispatch(Scope.t(), [option()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def dispatch(%Scope{} = scope, opts \\ []) do
    handler = Keyword.get(opts, :handler, &no_jobs/1)
    batch = Keyword.get(opts, :batch, @batch)

    result =
      OutboxStore.in_scope(scope, fn _status ->
        events = OutboxStore.claim(batch)
        jobs = Enum.flat_map(events, handler)
        if jobs != [], do: Oban.insert_all(jobs)
        _ = OutboxStore.mark_dispatched(Enum.map(events, & &1.id))
        events
      end)

    with {:ok, events} <- result do
      publish(scope, events, Keyword.get(opts, :publish, &Signal.publish/2))
      {:ok, length(events)}
    end
  end

  # T-86
  @doc "Discovers scopes with pending rows and dispatches one batch for each; returns the total dispatched."
  @spec run_once([option()]) :: non_neg_integer()
  def run_once(opts \\ []) do
    opts
    |> Keyword.get(:scopes, @scopes)
    |> OutboxStore.pending_scopes()
    |> Enum.reduce(0, fn {tenant_id, environment, _oldest}, total ->
      with {:ok, scope} <- Scope.new(tenant_id, environment),
           {:ok, count} <- dispatch(scope, opts) do
        total + count
      else
        {:error, reason} ->
          Logger.warning("outbox dispatch failed for a scope", reason: inspect(reason))
          total
      end
    end)
  end

  # TN-17
  @doc "Returns the signal topic of a stream in a scope, or an error when the stream key has no valid topic form."
  @spec stream_topic(Scope.t(), String.t()) :: {:ok, Signal.topic()} | {:error, Relay.Error.t()}
  def stream_topic(%Scope{} = scope, stream_key) when is_binary(stream_key) do
    Signal.topic(
      Scope.tenant_text(scope),
      Relay.Environment.dump(scope.environment),
      ["stream" | String.split(stream_key, ":")]
    )
  end

  @doc "Returns the system channel that wakes the outbox dispatchers."
  @spec wake_topic() :: Signal.topic()
  def wake_topic, do: Key.system_channel(["signal", "outbox"])

  # INV-53
  @doc "Wakes the outbox dispatchers; call it after a transaction that appended outbox rows commits."
  @spec wake() :: :ok | {:error, Relay.Error.t()}
  def wake, do: Signal.publish(wake_topic(), 0)

  defp publish(scope, events, publish) do
    events
    |> Enum.group_by(& &1.stream_key, & &1.seq)
    |> Enum.each(fn {stream_key, seqs} ->
      with {:ok, topic} <- stream_topic(scope, stream_key),
           :ok <- publish.(topic, Enum.max(seqs)) do
        :ok
      else
        {:error, _reason} ->
          :telemetry.execute([:relay, :outbox, :signal, :lost], %{count: 1}, %{})
      end
    end)
  end

  defp no_jobs(_event), do: []
end
