defmodule Relay.Platform.Valkey do
  @moduledoc """
  Valkey port. Valkey never holds a record of truth: it carries signals, counters and short-lived entries only, and losing it costs latency, not data. Writes take a `Relay.Platform.Valkey.Key`, so every stored entry is tenant scoped and expires.

  A process that subscribes to a channel receives `{:valkey, :up, channel}` once the subscription is confirmed (again after every reconnect), `{:valkey, :message, channel, payload}` for each published message and `{:valkey, :down}` when the connection is lost. A subscriber treats the channel as down until it receives `:up`.
  """

  alias Relay.Platform.Valkey.Key

  @type adapter :: module()
  @type channel :: String.t()
  @type reply :: nil | integer() | String.t() | [reply()]

  @callback command([String.t()]) :: {:ok, reply()} | {:error, term()}
  @callback pipeline([[String.t()]]) :: {:ok, [reply()]} | {:error, term()}
  @callback subscribe(channel()) :: :ok | {:error, term()}
  @callback unsubscribe(channel()) :: :ok

  # T-57
  @doc "Returns the configured adapter."
  @spec adapter() :: adapter()
  def adapter, do: :relay |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(:adapter)

  # TN-17
  # T-9 (7)
  @doc "Stores a short-lived value under a tenant key with the key's time to live."
  @spec put(Key.t(), String.t(), adapter()) :: :ok | {:error, Relay.Error.t()}
  def put(%Key{name: name, ttl_ms: ttl_ms}, value, adapter \\ adapter()) when is_binary(value) do
    :ok = guard()

    case adapter.command(["SET", name, value, "PX", Integer.to_string(ttl_ms)]) do
      {:ok, "OK"} -> :ok
      other -> failure(other)
    end
  end

  @doc "Reads a short-lived value; a missing or expired entry is `{:ok, nil}`."
  @spec get(Key.t(), adapter()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def get(%Key{name: name}, adapter \\ adapter()) do
    :ok = guard()

    case adapter.command(["GET", name]) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, value}
      other -> failure(other)
    end
  end

  # T-10
  @doc "Publishes a message on a channel."
  @spec publish(channel(), String.t(), adapter()) :: :ok | {:error, Relay.Error.t()}
  def publish(channel, payload, adapter \\ adapter())
      when is_binary(channel) and is_binary(payload) do
    :ok = guard()

    case adapter.command(["PUBLISH", channel, payload]) do
      {:ok, receivers} when is_integer(receivers) -> :ok
      other -> failure(other)
    end
  end

  @doc "Publishes several messages on a channel in one round trip."
  @spec publish_many(channel(), [String.t()], adapter()) :: :ok | {:error, Relay.Error.t()}
  def publish_many(channel, payloads, adapter \\ adapter())

  def publish_many(_channel, [], _adapter), do: :ok

  def publish_many(channel, payloads, adapter) when is_binary(channel) and is_list(payloads) do
    :ok = guard()

    case adapter.pipeline(Enum.map(payloads, &["PUBLISH", channel, &1])) do
      {:ok, replies} when is_list(replies) ->
        if Enum.all?(replies, &is_integer/1), do: :ok, else: failure({:ok, replies})

      other ->
        failure(other)
    end
  end

  @doc "Subscribes the calling process to a channel."
  @spec subscribe(channel(), adapter()) :: :ok | {:error, Relay.Error.t()}
  def subscribe(channel, adapter \\ adapter()) when is_binary(channel) do
    :ok = guard()

    case adapter.subscribe(channel) do
      :ok -> :ok
      other -> failure(other)
    end
  end

  @doc "Unsubscribes the calling process from a channel."
  @spec unsubscribe(channel(), adapter()) :: :ok
  def unsubscribe(channel, adapter \\ adapter()) when is_binary(channel),
    do: adapter.unsubscribe(channel)

  # T-9 (6)
  @doc "Reads the server's eviction policy."
  @spec eviction_policy(adapter()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def eviction_policy(adapter \\ adapter()) do
    :ok = guard()

    with {:ok, info} when is_binary(info) <- adapter.command(["INFO", "memory"]),
         [_, policy] <- Regex.run(~r/^maxmemory_policy:(\S+)/m, info) do
      {:ok, policy}
    else
      {:error, _} = error -> failure(error)
      _ -> {:error, Relay.Error.new(:valkey_reply, "eviction policy missing from INFO memory")}
    end
  end

  # INV-55
  defp guard, do: Relay.NetworkGuard.check!(:valkey)

  defp failure({:error, reason}),
    do:
      {:error,
       Relay.Error.new(:valkey_unavailable, "Valkey command failed", %{
         reason: reason_code(reason)
       })}

  defp failure(_other),
    do: {:error, Relay.Error.new(:valkey_reply, "unexpected Valkey reply")}

  defp reason_code(%{reason: reason}) when is_atom(reason), do: reason
  defp reason_code(%{__exception__: true} = error), do: error.__struct__
  defp reason_code(reason) when is_atom(reason), do: reason
  defp reason_code(_reason), do: :unknown
end
