defmodule Relay.Platform.Signal do
  @moduledoc """
  Cross-node signals. A signal says only that something new exists on a topic, with a sequence number; it never carries data. A subscriber reacts by reading from PostgreSQL from its own cursor, so a lost signal costs latency, never correctness.

  Subscribers receive `{:relay_signal, topic, {:seq, n}}` for a signal and `{:relay_signal, topic, :poll}` when they should re-read without one: right after the subscription is confirmed, after a reconnect, and at a short interval for as long as Valkey is unavailable.
  """

  alias Relay.Platform.Signal.Hub
  alias Relay.Platform.Valkey
  alias Relay.Platform.Valkey.Key

  @type topic :: String.t()
  @type event :: {:seq, non_neg_integer()} | :poll
  @type message :: {:relay_signal, topic(), event()}

  # TN-17
  @doc "Builds a tenant-scoped topic."
  @spec topic(Key.segment(), Key.segment(), [Key.segment(), ...]) ::
          {:ok, topic()} | {:error, Relay.Error.t()}
  def topic(tenant_id, environment, segments) when is_list(segments),
    do: Key.channel(tenant_id, environment, ["signal" | segments])

  # INV-52
  # INV-53
  # T-9 (2)
  @doc "Publishes a signal carrying only the sequence number; call it after the transaction commits."
  @spec publish(topic(), non_neg_integer(), Valkey.adapter()) :: :ok | {:error, Relay.Error.t()}
  def publish(topic, seq, adapter \\ Valkey.adapter())
      when is_binary(topic) and is_integer(seq) and seq >= 0,
      do: Valkey.publish(topic, Integer.to_string(seq), adapter)

  # T-9 (3)
  @doc "Subscribes the calling process to a topic."
  @spec subscribe(topic(), GenServer.server()) :: :ok
  def subscribe(topic, hub \\ Hub) when is_binary(topic), do: Hub.subscribe(hub, topic, self())

  @doc "Unsubscribes the calling process from a topic."
  @spec unsubscribe(topic(), GenServer.server()) :: :ok
  def unsubscribe(topic, hub \\ Hub) when is_binary(topic),
    do: Hub.unsubscribe(hub, topic, self())

  @doc "Decodes a signal payload; anything but a decimal sequence number asks for a re-read."
  @spec decode(String.t()) :: event()
  def decode(payload) when is_binary(payload) do
    case Integer.parse(payload) do
      {seq, ""} when seq >= 0 -> {:seq, seq}
      _ -> :poll
    end
  end
end
