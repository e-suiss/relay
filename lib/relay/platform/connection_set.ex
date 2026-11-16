defmodule Relay.Platform.ConnectionSet do
  @moduledoc """
  A set of live connections on Valkey (`priv/valkey/connection_set.lua`): a sorted set per key whose members are scored by the server's `TIME` in milliseconds of their last touch. Members not touched within the time to live drop out on the next call, and the key itself expires with the last touch. Joining beyond the maximum removes the lowest members in text order; callers that start their members with a fixed-width connection time make that the oldest connections. A member that finds itself gone on its next touch was removed.

  Keys are `relay:t:<tenant>:<environment>:<segments>`. Valkey holds no record of truth: when the call fails the result is an error and the caller decides what an unknown set means.
  """

  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key
  alias Relay.Platform.Valkey.Script

  @external_resource Script.path("connection_set")
  @script Script.read!("connection_set")

  @type path :: [String.t(), ...]
  @type option :: {:adapter, module()}

  # T-9
  @doc "The script this module runs, for `SCRIPT LOAD` at start."
  @spec scripts() :: [Script.t()]
  def scripts, do: [@script]

  # IN-52
  @doc "Adds `member` and returns the number of members after it and the number of the lowest members removed to keep at most `max`."
  @spec join(Relay.Scope.t(), path(), String.t(), pos_integer(), pos_integer(), [option()]) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, Relay.Error.t()}
  def join(scope, segments, member, ttl_ms, max, opts \\ []) do
    with {:ok, [count, evicted]} <- run(scope, segments, ["join", member, ttl_ms, max], opts),
         do: {:ok, {count, evicted}}
  end

  # IN-52
  @doc "Refreshes `member`; `:gone` when it is no longer in the set."
  @spec touch(Relay.Scope.t(), path(), String.t(), pos_integer(), [option()]) ::
          :ok | :gone | {:error, Relay.Error.t()}
  def touch(scope, segments, member, ttl_ms, opts \\ []) do
    case run(scope, segments, ["touch", member, ttl_ms, 0], opts) do
      {:ok, [1, _]} -> :ok
      {:ok, [_, _]} -> :gone
      {:error, _} = error -> error
    end
  end

  @doc "Removes `member`."
  @spec leave(Relay.Scope.t(), path(), String.t(), pos_integer(), [option()]) ::
          :ok | {:error, Relay.Error.t()}
  def leave(scope, segments, member, ttl_ms, opts \\ []) do
    with {:ok, _reply} <- run(scope, segments, ["leave", member, ttl_ms, 0], opts), do: :ok
  end

  # IN-40
  @doc "True when a live member ends with `suffix`."
  @spec any_suffix?(Relay.Scope.t(), path(), String.t(), pos_integer(), [option()]) ::
          {:ok, boolean()} | {:error, Relay.Error.t()}
  def any_suffix?(scope, segments, suffix, ttl_ms, opts \\ []) do
    with {:ok, [found, _]} <- run(scope, segments, ["suffix", suffix, ttl_ms, 0], opts),
         do: {:ok, found == 1}
  end

  defp run(%Relay.Scope{} = scope, segments, args, opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &Valkey.adapter/0)
    [_op, _member, ttl_ms, _max] = args
    tenant = Relay.Id.to_string(scope.tenant_id)
    environment = Relay.Environment.dump(scope.environment)

    with {:ok, key} <- Key.new(tenant, environment, segments, ttl_ms),
         do: reply(Valkey.eval(@script, key, args, adapter))
  end

  defp reply({:ok, [_, _]} = ok), do: ok
  defp reply({:ok, _other}), do: {:error, unexpected()}
  defp reply({:error, _} = error), do: error

  defp unexpected, do: Relay.Error.new(:valkey_reply, "unexpected connection set reply")
end
