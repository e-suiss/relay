defmodule Relay.Platform.SlidingSet do
  @moduledoc """
  A sliding window of distinct members on Valkey: a sorted set per key, scored by the server's `TIME` in milliseconds when the member was added (`priv/valkey/sliding_set.lua`). Adding a member that is already in the window keeps its first time, so a repeated add is idempotent; members older than the window are trimmed when one is added. Counting leaves out one given member, so a re-evaluation of the same work does not count itself, and when the count reaches a limit it also returns the time at which the window drops below it.

  Keys are `relay:t:<tenant>:<environment>:<segments>` and expire one second after the window. Valkey only: while the node's limit backend is on PostgreSQL, or when the call fails, the result is an error and the caller decides what an unknown count means.
  """

  alias Relay.Platform.Backend
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script

  @external_resource Script.path("sliding_set")
  @script Script.read!("sliding_set")

  @type count :: %{
          count: non_neg_integer(),
          free_at_ms: non_neg_integer() | nil,
          now_ms: non_neg_integer()
        }
  @type option :: {:backend, GenServer.name()} | {:adapter, module()}
  @type path :: [String.t(), ...]

  # T-9
  @doc "The script this module runs, for `SCRIPT LOAD` at start."
  @spec scripts() :: [Script.t()]
  def scripts, do: [@script]

  # PC-50
  # PC-58 (6)
  @doc "Counts the members added within the last `window_ms`, leaving out `member`; when the count is at least `limit`, `free_at_ms` is the server time at which it drops below `limit`, otherwise `nil`."
  @spec count(Relay.Scope.t(), path(), pos_integer(), String.t(), pos_integer(), [option()]) ::
          {:ok, count()} | {:error, Relay.Error.t()}
  def count(%Relay.Scope{} = scope, segments, window_ms, member, limit, opts \\ [])
      when is_integer(window_ms) and window_ms > 0 and is_integer(limit) and limit > 0 do
    case run(scope, segments, window_ms, ["count", window_ms, member, limit], opts) do
      {:ok, [count, 0, now]} -> {:ok, %{count: count, free_at_ms: nil, now_ms: now}}
      {:ok, [count, free_at, now]} -> {:ok, %{count: count, free_at_ms: free_at, now_ms: now}}
      {:error, _} = error -> error
    end
  end

  # PC-50
  # PC-58 (6)
  @doc "Adds `member` to the window unless it is already there and returns the number of members in the window."
  @spec add(Relay.Scope.t(), path(), pos_integer(), String.t(), [option()]) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def add(%Relay.Scope{} = scope, segments, window_ms, member, opts \\ [])
      when is_integer(window_ms) and window_ms > 0 do
    case run(scope, segments, window_ms, ["add", window_ms, member, 1], opts) do
      {:ok, [count, 0, _now]} -> {:ok, count}
      {:error, _} = error -> error
    end
  end

  defp run(scope, segments, window_ms, args, opts) do
    server = Keyword.get(opts, :backend, Backend)
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)

    with {:ok, key} <- key(scope, segments, window_ms),
         :valkey <- mode(window_ms, server) do
      reply(Backend.call_valkey(fn -> Valkey.eval(@script, key, args, adapter) end, server))
    end
  end

  defp mode(window_ms, server) do
    case Backend.current_mode(window_ms, server) do
      :pg -> {:error, Relay.Error.new(:valkey_unavailable, "the limit backend is on PostgreSQL")}
      _valkey_or_dual -> :valkey
    end
  end

  defp reply({:ok, [_count, _free_at, _now]} = ok), do: ok
  defp reply({:error, _} = error), do: error

  defp reply(_other),
    do: {:error, Relay.Error.new(:valkey_reply, "unexpected sliding set reply")}

  defp key(%Relay.Scope{tenant_id: tenant_id, environment: environment}, segments, window_ms) do
    Key.new(
      Relay.Id.to_string(tenant_id),
      Relay.Environment.dump(environment),
      segments,
      window_ms + 1_000
    )
  end
end
