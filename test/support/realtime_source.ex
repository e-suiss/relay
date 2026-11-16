defmodule RelayTest.RealtimeSource do
  @moduledoc "A `Relay.Realtime.Source` for tests: an in-memory stream per subscriber held by a named agent. Cursors are decimal sequence numbers; the signal topic is the scope's `realtime_test` topic of the subscriber."

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform, Relay.Realtime], exports: []

  @behaviour Relay.Realtime.Source

  @counters %{unseen: 0, unread: 0, total: 0, version: 0}

  @doc "Starts the agent under the test supervisor and makes this module the realtime source until the test exits."
  @spec install!() :: :ok
  def install! do
    {:ok, _pid} =
      ExUnit.Callbacks.start_supervised(%{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> %{} end, [name: __MODULE__]]}
      })

    previous = Application.get_env(:relay, Relay.Realtime)
    Application.put_env(:relay, Relay.Realtime, source: __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, Relay.Realtime, previous),
        else: Application.delete_env(:relay, Relay.Realtime)
    end)
  end

  @doc "Appends a change to the subscriber's stream, moves its counters and returns the new sequence number."
  @spec append(Relay.Id.t(), String.t(), map()) :: pos_integer()
  def append(subscriber_id, type, data) do
    Agent.get_and_update(__MODULE__, fn state ->
      stream = Map.get(state, subscriber_id, new())
      seq = stream.seq + 1
      counters = %{stream.counters | unseen: stream.counters.unseen + 1, version: seq}
      changes = stream.changes ++ [{seq, %{t: type, d: data}}]
      stream = %{stream | seq: seq, changes: changes, counters: counters}
      {seq, Map.put(state, subscriber_id, stream)}
    end)
  end

  @doc "Makes every read of the subscriber's stream fail with `reason`, or succeed again with `nil`."
  @spec fail(Relay.Id.t(), term()) :: :ok
  def fail(subscriber_id, reason), do: update(subscriber_id, &%{&1 | fail: reason})

  @doc "The signal topic of a subscriber's test stream."
  @spec topic(Relay.Scope.t(), Relay.Id.t()) :: String.t()
  def topic(scope, subscriber_id) do
    {:ok, topic} =
      Relay.Platform.signal_topic(
        Relay.Scope.tenant_text(scope),
        Relay.Environment.dump(scope.environment),
        ["realtime_test", Relay.Id.to_string(subscriber_id)]
      )

    topic
  end

  @impl true
  def signal_topic(scope, subscriber_id), do: {:ok, topic(scope, subscriber_id)}

  @impl true
  def head(_scope, subscriber_id), do: {:ok, Integer.to_string(stream(subscriber_id).seq)}

  @impl true
  def changes(_scope, subscriber_id, cursor, limit) do
    stream = stream(subscriber_id)

    case {stream.fail, Integer.parse(cursor)} do
      {nil, {since, ""}} when since >= 0 and since <= stream.seq ->
        page(stream, since, cursor, limit)

      {nil, _invalid} ->
        {:resync_required, "cursor_invalid"}

      {reason, _cursor} ->
        {:error, reason}
    end
  end

  @impl true
  def counters(_scope, subscriber_id) do
    case stream(subscriber_id) do
      %{fail: nil, counters: counters} -> {:ok, counters}
      %{fail: reason} -> {:error, reason}
    end
  end

  defp page(stream, since, cursor, limit) do
    after_cursor = Enum.filter(stream.changes, fn {seq, _change} -> seq > since end)
    taken = Enum.take(after_cursor, limit)

    next =
      case List.last(taken) do
        {seq, _change} -> Integer.to_string(seq)
        nil -> cursor
      end

    changes =
      Enum.map(taken, fn {seq, change} -> Map.put(change, :cursor, Integer.to_string(seq)) end)

    {:ok, %{changes: changes, cursor: next, truncated: length(after_cursor) > limit}}
  end

  defp stream(subscriber_id), do: Agent.get(__MODULE__, &Map.get(&1, subscriber_id, new()))

  defp update(subscriber_id, fun) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, subscriber_id, fun.(Map.get(state, subscriber_id, new())))
    end)
  end

  defp new, do: %{seq: 0, changes: [], counters: @counters, fail: nil}
end
