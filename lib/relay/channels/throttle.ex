defmodule Relay.Channels.Throttle do
  @moduledoc """
  The adaptive throttle of the provider accounts (CH-17, §12.3.4), node local like the circuit breakers: a factor from 0.1 to 1 per account that scales the account layer of the provider limits (`Relay.Channels.Limits`). A 429 or throttling answer halves it, every success raises it by 0.05 (AIMD); an account never seen is at 1. The provider's `Retry-After` is applied by the retry plan on top of this and always wins.

  The table is protected: job processes read it directly and send their answers to the owner, which applies the steps in order.
  """

  use GenServer

  @table __MODULE__.Table
  @floor 0.1
  @step 0.05

  @doc "Starts the owner of the throttle table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # CH-17
  @doc "The factor of an account; 1 for an account never throttled or without an identifier."
  @spec factor(Relay.Id.t() | nil) :: float()
  def factor(nil), do: 1.0

  def factor(account_id) do
    case :ets.lookup(@table, account_id) do
      [{_id, factor}] -> factor
      [] -> 1.0
    end
  rescue
    ArgumentError -> 1.0
  end

  # CH-17
  @doc "Moves an account's factor after a throttled or successful call."
  @spec record(Relay.Id.t(), :throttled | :success) :: :ok
  def record(account_id, outcome) when outcome in [:throttled, :success] do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, account_id, outcome})
    end
  end

  # CH-17
  @doc "One AIMD step: a throttled call halves the factor down to 0.1, a success adds 0.05 up to 1."
  @spec step(float(), :throttled | :success) :: float()
  def step(factor, :throttled), do: max(factor / 2, @floor)
  def step(factor, :success), do: min(Float.round(factor + @step, 4), 1.0)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :protected,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl true
  def handle_cast({:record, account_id, outcome}, state) do
    current = factor(account_id)
    next = step(current, outcome)
    if next != current, do: :ets.insert(@table, {account_id, next})
    {:noreply, state}
  end
end
