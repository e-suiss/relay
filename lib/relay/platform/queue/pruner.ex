defmodule Relay.Platform.Queue.Pruner do
  @moduledoc """
  Relay's queue cleaner, used instead of `Oban.Plugins.Pruner`. On the leader only, it periodically removes `completed` jobs a day after completion and `cancelled` jobs seven days after cancellation, through the `relay_queue` role; `discarded` jobs are never removed here (OP-12).

  Options: `:interval` (ms, default 60 000), `:limit` (rows per run, default 10 000), `:completed_after` and `:cancelled_after` (ms).
  """

  @behaviour Oban.Plugin

  use GenServer

  alias Relay.Platform.Queue.PrunerStore

  require Logger

  @day 86_400_000
  @defaults [interval: 60_000, limit: 10_000, completed_after: @day, cancelled_after: 7 * @day]

  @impl Oban.Plugin
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Oban.Plugin
  def validate(opts) do
    opts
    |> Keyword.drop([:conf, :name])
    |> Enum.find_value(:ok, fn
      {key, value} when key in [:interval, :limit, :completed_after, :cancelled_after] ->
        if is_integer(value) and value > 0,
          do: nil,
          else: {:error, "expected #{key} to be a positive integer"}

      {key, _value} ->
        {:error, "unknown option #{inspect(key)}"}
    end)
  end

  # OP-12
  # T-15
  @doc "Returns the cut-off times for completed and cancelled rows at `now`."
  @spec cutoffs(DateTime.t(), keyword()) :: {NaiveDateTime.t(), NaiveDateTime.t()}
  def cutoffs(%DateTime{} = now, opts) do
    opts = Keyword.merge(@defaults, opts)
    naive = DateTime.to_naive(now)

    {NaiveDateTime.add(naive, -opts[:completed_after], :millisecond),
     NaiveDateTime.add(naive, -opts[:cancelled_after], :millisecond)}
  end

  @impl GenServer
  def init(opts) do
    case validate(opts) do
      :ok ->
        state = Keyword.merge(@defaults, opts)
        schedule(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info(:prune, state) do
    if Oban.Peer.leader?(state[:conf]), do: prune(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp prune(state) do
    {completed, cancelled} = cutoffs(Relay.Clock.utc_now(), state)

    case PrunerStore.prune(completed, cancelled, state[:limit]) do
      {:ok, count} ->
        :telemetry.execute([:relay, :queue, :pruned], %{count: count}, %{})

      {:error, error} ->
        Logger.warning("queue cleaner failed", error: inspect(error.__struct__))
    end
  end

  defp schedule(state), do: Process.send_after(self(), :prune, state[:interval])
end
