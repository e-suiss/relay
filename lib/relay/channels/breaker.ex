defmodule Relay.Channels.Breaker do
  @moduledoc """
  The two-level, tenant-isolated circuit breaker of a node (T-25, INV-40). The `provider` level counts transport errors, 5xx, timeouts, 429 and unknown failures from every tenant's calls on this node; the `tenant_provider` level counts authentication, sender configuration and quota failures of one tenant's provider account. A tenant's breaker never stops another tenant's calls, the provider breaker does not open the tenant breakers, and a tenant's failures add no score to the provider breaker.

  State lives only on the node, in one protected ETS table whose values are `:atomics` references (T-25 (9)): the table owner inserts a key the first time it is seen, after that the hot path reads and updates counters without calling a central process, and no atom is created from a tenant identifier. Parameters come from the `channel_parameters` breaker row of the channel and provider; failure weights from its failure weight rows. Durations use the monotonic clock (T-11). A tenant breaker that saw no call for 15 minutes is dropped.

  A transition emits `[:relay, :breaker, :transition]` with `%{level, provider, from, to}`; when a provider breaker closes, the automatic dead letter replay is queued (T-29 (6)).
  """

  use GenServer

  alias Relay.Channels.Breaker.Core

  @table __MODULE__.Table
  @sweep_ms 60_000
  @idle_ms 15 * 60_000
  @never -4_611_686_018_427_387_904

  @state 1
  @opened_at 2
  @open_until 3
  @open_count 4
  @probes 5
  @successes 6
  @last_seen 7
  @ring 8
  @size @ring + 4 * 10

  @closed 0
  @open 1
  @half_open 2

  @type level :: :tenant_provider | :provider
  @type decision :: :allow | :probe | {:reject, :breaker_open, non_neg_integer(), String.t()}
  @type target :: %{
          required(:tenant_id) => Relay.Id.t(),
          required(:environment) => Relay.Environment.t(),
          required(:channel) => String.t() | atom(),
          required(:provider) => String.t(),
          optional(:provider_account_id) => Relay.Id.t() | nil
        }
  @type outcome :: :success | {:failure, String.t() | atom(), String.t() | atom() | nil}
  @opaque ticket :: map()

  @doc "Starts the owner of the breaker table and its idle sweep."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # T-25 (1)
  # T-25 (2)
  # T-25 (9)
  # INV-40
  @doc """
  Asks both breakers of a target whether a call may go: `:allow`, `:probe` (a half-open trial) or `{:reject, :breaker_open, retry_after_ms, rule_id}`. A rejection is a decision: the job snoozes for `retry_after_ms` without counting an attempt, or fails over. Pass the returned ticket to `record/3` with the call's outcome.
  """
  @spec check(Relay.ChannelParameters.t(), target(), integer()) :: {decision(), ticket()}
  def check(parameters, target, now \\ Relay.Clock.monotonic_ms()) do
    {:ok, row, _version} =
      Relay.ChannelParameters.breaker(parameters, target.channel, target.provider)

    provider = entry({:provider, target.provider}, "provider:" <> target.provider, target, now)
    tenant = entry(tenant_key(target), tenant_text(target), target, now)
    ticket = %{parameters: parameters, row: row, provider: target.provider}

    case admit(provider, now, row) do
      {:reject, after_ms} ->
        {{:reject, :breaker_open, after_ms, "breaker.provider." <> target.provider}, ticket}

      provider_decision ->
        admit_tenant(ticket, provider, provider_decision, tenant, now)
    end
  end

  defp admit_tenant(ticket, provider, provider_decision, tenant, now) do
    case admit(tenant, now, ticket.row) do
      {:reject, after_ms} ->
        release(provider, provider_decision)
        {{:reject, :breaker_open, after_ms, "breaker.tenant_provider"}, ticket}

      tenant_decision ->
        decision = if :probe in [provider_decision, tenant_decision], do: :probe, else: :allow

        {decision,
         Map.put(ticket, :levels, [
           {:provider, provider, provider_decision},
           {:tenant_provider, tenant, tenant_decision}
         ])}
    end
  end

  # T-25 (3)
  # T-25 (4)
  # T-25 (5)
  # CH-15
  @doc "Records the outcome of an admitted call; `latency_ms` feeds the latency threshold when the row sets one."
  @spec record(ticket(), outcome(), non_neg_integer() | nil, integer()) :: :ok
  def record(ticket, outcome, latency_ms \\ nil, now \\ Relay.Clock.monotonic_ms())

  def record(%{levels: levels} = ticket, outcome, latency_ms, now) do
    {weight, level} = weight(ticket.parameters, outcome)
    slow? = Core.slow?(ticket.row, latency_ms)

    for {name, entry, decision} <- levels do
      level_weight = if name == level, do: weight, else: 0
      result(entry, ticket, decision, level_weight, slow?, now)
    end

    :ok
  end

  def record(_ticket, _outcome, _latency_ms, _now), do: :ok

  @doc "Returns the state of the provider breaker of `provider` on this node."
  @spec provider_state(String.t()) :: Core.state() | nil
  def provider_state(provider), do: state({:provider, provider})

  @doc "Returns the state of a target's tenant breaker on this node."
  @spec tenant_state(target()) :: Core.state() | nil
  def tenant_state(target), do: state(tenant_key(target))

  defp state(key) do
    case :ets.lookup(@table, key) do
      [{^key, ref, _text}] -> state_name(:atomics.get(ref, @state))
      [] -> nil
    end
  end

  defp weight(_parameters, :success), do: {0, :provider}

  defp weight(parameters, {:failure, class, condition}),
    do: Relay.ChannelParameters.weight(parameters, class, condition)

  defp tenant_key(target) do
    {:tenant_provider, target.tenant_id, Relay.Environment.dump(target.environment),
     Map.get(target, :provider_account_id) || target.provider}
  end

  defp tenant_text(target) do
    account =
      case Map.get(target, :provider_account_id) do
        nil -> target.provider
        id -> Relay.Id.to_string(id)
      end

    Enum.join(
      [
        "tenant_provider",
        Relay.Id.to_string(target.tenant_id),
        Relay.Environment.dump(target.environment),
        account
      ],
      ":"
    )
  end

  defp entry(key, text, target, now) do
    ref =
      case :ets.lookup(@table, key) do
        [{^key, ref, _text}] ->
          ref

        [] ->
          GenServer.call(__MODULE__, {:insert, key, text, now})
      end

    :atomics.put(ref, @last_seen, now)
    %{ref: ref, level: elem(key, 0), provider: target.provider, text: text}
  end

  defp new_ref do
    ref = :atomics.new(@size, signed: true)
    clear_window(ref)
    ref
  end

  defp admit(%{ref: ref} = entry, now, row) do
    case :atomics.get(ref, @state) do
      @closed ->
        :allow

      @open ->
        until = :atomics.get(ref, @open_until)

        cond do
          now < until ->
            {:reject, until - now}

          :atomics.compare_exchange(ref, @state, @open, @half_open) == :ok ->
            emit(entry, :open, :half_open)
            probe(ref, row)

          true ->
            admit(entry, now, row)
        end

      @half_open ->
        probe(ref, row)
    end
  end

  defp probe(ref, row) do
    if Core.probe?(:atomics.add_get(ref, @probes, 1) - 1, row) do
      :probe
    else
      :atomics.sub(ref, @probes, 1)
      {:reject, Core.bucket_ms(row)}
    end
  end

  defp release(%{ref: ref}, :probe), do: :atomics.sub(ref, @probes, 1)
  defp release(_entry, _decision), do: :ok

  defp result(%{ref: ref} = entry, ticket, :probe, weight, _slow?, now) do
    :atomics.sub(ref, @probes, 1)

    cond do
      :atomics.get(ref, @state) != @half_open ->
        :ok

      weight > 0 ->
        open(entry, ticket.row, now, @half_open)

      Core.closes?(:atomics.add_get(ref, @successes, 1), ticket.row) ->
        if :atomics.compare_exchange(ref, @state, @half_open, @closed) == :ok do
          clear_window(ref)
          emit(entry, :half_open, :closed)
        end

      true ->
        :ok
    end
  end

  defp result(%{ref: ref} = entry, ticket, :allow, weight, slow?, now) do
    if :atomics.get(ref, @state) == @closed do
      {calls, score, slow} = add(ref, ticket.row, now, weight, slow?)

      if Core.trip?(calls, score, slow, ticket.row),
        do: open(entry, ticket.row, now, @closed)
    end

    :ok
  end

  defp add(ref, row, now, weight, slow?) do
    bucket = Core.div_floor(now, Core.bucket_ms(row))
    base = @ring + 4 * Integer.mod(bucket, Core.buckets())
    held = :atomics.get(ref, base)

    if held != bucket and :atomics.compare_exchange(ref, base, held, bucket) == :ok do
      :atomics.put(ref, base + 1, 0)
      :atomics.put(ref, base + 2, 0)
      :atomics.put(ref, base + 3, 0)
    end

    :atomics.add(ref, base + 1, 1)
    :atomics.add(ref, base + 2, weight)
    if slow?, do: :atomics.add(ref, base + 3, 1)

    for slot <- 0..(Core.buckets() - 1),
        at = @ring + 4 * slot,
        id = :atomics.get(ref, at),
        id > bucket - Core.buckets() and id <= bucket,
        reduce: {0, 0, 0} do
      {c, s, l} ->
        {c + :atomics.get(ref, at + 1), s + :atomics.get(ref, at + 2),
         l + :atomics.get(ref, at + 3)}
    end
  end

  defp open(%{ref: ref, text: text} = entry, row, now, from) do
    count = :atomics.get(ref, @open_count) + 1
    :atomics.put(ref, @open_until, Core.open_until(now, count, row, Atom.to_string(node()), text))
    :atomics.put(ref, @opened_at, now)
    :atomics.put(ref, @probes, 0)
    :atomics.put(ref, @successes, 0)

    if :atomics.compare_exchange(ref, @state, from, @open) == :ok do
      :atomics.add(ref, @open_count, 1)
      emit(entry, state_name(from), :open)
    end

    :ok
  end

  defp clear_window(ref) do
    for slot <- 0..(Core.buckets() - 1), do: :atomics.put(ref, @ring + 4 * slot, @never)
    :ok
  end

  defp emit(entry, from, to) do
    :telemetry.execute([:relay, :breaker, :transition], %{count: 1}, %{
      level: entry.level,
      provider: entry.provider,
      from: from,
      to: to
    })
  end

  defp state_name(@closed), do: :closed
  defp state_name(@open), do: :open
  defp state_name(@half_open), do: :half_open

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :protected,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule(Keyword.get(opts, :sweep_ms, @sweep_ms))
    {:ok, %{sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)}}
  end

  @impl GenServer
  def handle_call({:insert, key, text, now}, _from, state) do
    ref =
      case :ets.lookup(@table, key) do
        [{^key, ref, _text}] ->
          ref

        [] ->
          ref = new_ref()
          :atomics.put(ref, @last_seen, now)
          true = :ets.insert(@table, {key, ref, text})
          ref
      end

    {:reply, ref, state}
  end

  def handle_call({:sweep, now}, _from, state), do: {:reply, drop_idle(now), state}

  @impl GenServer
  def handle_info(:sweep, state) do
    drop_idle(Relay.Clock.monotonic_ms())
    schedule(state.sweep_ms)
    {:noreply, state}
  end

  # T-25 (9)
  @doc "Drops the tenant breakers that saw no call for 15 minutes before `now`."
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now), do: GenServer.call(__MODULE__, {:sweep, now})

  defp drop_idle(now) do
    idle =
      for {{:tenant_provider, _, _, _} = key, ref, _text} <- :ets.tab2list(@table),
          now - :atomics.get(ref, @last_seen) >= @idle_ms,
          do: key

    Enum.each(idle, &:ets.delete(@table, &1))
    length(idle)
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)
end
