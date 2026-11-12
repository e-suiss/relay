defmodule Relay.Realtime.Admission do
  @moduledoc """
  The node's accept rate for new realtime connections (IN-34 (2), IN-52): a token bucket refilled at the contract's connections per second up to its burst. A connection that finds the bucket empty is refused with a `Retry-After` drawn uniformly from the contract's range, so refused clients do not come back together.
  """

  use GenServer

  @rate Relay.Limits.fetch!(["realtime", "accept_per_second"])
  @burst Relay.Limits.fetch!(["realtime", "accept_burst"])
  @retry_min Relay.Limits.fetch!(["realtime", "retry_after_seconds", "min"])
  @retry_max Relay.Limits.fetch!(["realtime", "retry_after_seconds", "max"])

  @type bucket :: %{tokens: float(), at_ms: integer(), rate: pos_integer(), burst: pos_integer()}

  @doc "Starts the bucket; `:rate` and `:burst` default to the contract's values."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # IN-52
  @doc "Takes one connection from the bucket, or answers the jittered `Retry-After` seconds."
  @spec take(GenServer.server()) :: :ok | {:error, pos_integer()}
  def take(server \\ __MODULE__), do: GenServer.call(server, :take)

  # IN-52
  @doc "A `Retry-After` in whole seconds, uniform over the contract's range."
  @spec retry_after() :: pos_integer()
  def retry_after, do: @retry_min + Relay.Random.uniform(@retry_max - @retry_min + 1) - 1

  # IN-52
  @doc "Refills a bucket up to `now_ms` and takes one token when a whole one is there."
  @spec step(bucket(), integer()) :: {:ok | :empty, bucket()}
  def step(%{tokens: tokens, at_ms: at_ms, rate: rate, burst: burst} = bucket, now_ms) do
    elapsed = max(now_ms - at_ms, 0)
    tokens = min(burst * 1.0, tokens + elapsed * rate / 1_000)

    if tokens >= 1.0,
      do: {:ok, %{bucket | tokens: tokens - 1.0, at_ms: now_ms}},
      else: {:empty, %{bucket | tokens: tokens, at_ms: now_ms}}
  end

  @impl GenServer
  def init(opts) do
    rate = Keyword.get(opts, :rate, @rate)
    burst = Keyword.get(opts, :burst, @burst)
    now_ms = Relay.Clock.monotonic_ms()
    {:ok, %{tokens: burst * 1.0, at_ms: now_ms, rate: rate, burst: burst}}
  end

  @impl GenServer
  def handle_call(:take, _from, bucket) do
    case step(bucket, Relay.Clock.monotonic_ms()) do
      {:ok, bucket} -> {:reply, :ok, bucket}
      {:empty, bucket} -> {:reply, {:error, retry_after()}, bucket}
    end
  end
end
