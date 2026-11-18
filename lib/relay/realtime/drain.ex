defmodule Relay.Realtime.Drain do
  @moduledoc """
  The node-local list of open realtime connections and the plan that closes them when the node stops (IN-34 (4), OP-87, T-5 (4)). Every WebSocket and SSE connection process registers itself here; when the node drains, the connections are split into batches spread evenly over the drain window, and each connection is closed with a reconnect hint drawn uniformly from the contract's `Retry-After` range, so the clients of a stopping node do not all come back to the remaining nodes in the same second.
  """

  @registry __MODULE__.Registry
  @key :connections

  # IN-34
  @doc "The node-local registry of open realtime connections."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg),
    do: Supervisor.child_spec({Registry, keys: :duplicate, name: @registry}, id: __MODULE__)

  # IN-34
  @doc "Registers the calling process as an open realtime connection of this node; it leaves the list when it exits."
  @spec track() :: :ok
  def track do
    if Process.whereis(@registry), do: {:ok, _owner} = Registry.register(@registry, @key, nil)
    :ok
  end

  # IN-34
  @doc "The open realtime connection processes of this node."
  @spec connections() :: [pid()]
  def connections do
    if Process.whereis(@registry),
      do: for({pid, _value} <- Registry.lookup(@registry, @key), do: pid),
      else: []
  end

  # IN-34
  # OP-87
  @doc "Splits `connections` into batches spread over `window_ms`, one batch every `interval_ms`: as many batches as the window holds, never an empty one, the earlier batches one larger when the count does not divide."
  @spec batches([term()], pos_integer(), pos_integer()) :: [[term()]]
  def batches([], _window_ms, _interval_ms), do: []

  def batches(connections, window_ms, interval_ms)
      when is_integer(window_ms) and window_ms > 0 and is_integer(interval_ms) and
             interval_ms > 0 do
    rounds = connections |> length() |> min(max(div(window_ms, interval_ms), 1))
    size = div(length(connections), rounds)
    extra = rem(length(connections), rounds)

    {batches, []} =
      Enum.map_reduce(0..(rounds - 1)//1, connections, fn round, left ->
        Enum.split(left, if(round < extra, do: size + 1, else: size))
      end)

    batches
  end

  # IN-34
  # IN-52
  @doc "The reconnect hint of a drained connection in whole seconds, uniform over the contract's `Retry-After` range."
  @spec reconnect_hint() :: pos_integer()
  def reconnect_hint, do: Relay.Realtime.Admission.retry_after()
end
