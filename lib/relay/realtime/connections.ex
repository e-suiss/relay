defmodule Relay.Realtime.Connections do
  @moduledoc """
  The subscriber's live realtime connections on Valkey (IN-40, IN-52): one connection set per subscriber (`Relay.Platform.connection_set_join/5`), one member per WebSocket or SSE connection, `<connected at, ms, 15 digits>:<connection id>:<device id or ->`. A connection refreshes its member every heartbeat; a member that is not refreshed within the contract's lifetime drops out, so a node that dies leaves nothing behind for long. Joining beyond the contract's connections per subscriber removes the oldest members, and a connection that finds its member gone on its next heartbeat closes.

  The set is short-lived state, never a record: when Valkey is unavailable a join or heartbeat fails open (the connection stays) and `connected?/3` is `false`.
  """

  @ttl_ms Relay.Limits.fetch!(["realtime", "connection_ttl_seconds"]) * 1_000
  @heartbeat_ms Relay.Limits.fetch!(["realtime", "heartbeat_seconds"]) * 1_000
  @max Relay.Limits.fetch!(["realtime", "max_connections_per_subscriber"])
  @device ~r/\A[A-Za-z0-9][A-Za-z0-9_\-]{0,63}\z/
  @none "-"

  @type member :: String.t()

  # IN-40
  @doc "The heartbeat interval of a connection in milliseconds."
  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms, do: @heartbeat_ms

  # IN-40
  @doc "True when `device_id` is a well-formed device identifier."
  @spec device?(term()) :: boolean()
  def device?(device_id), do: is_binary(device_id) and Regex.match?(@device, device_id)

  # IN-52
  @doc "Adds a connection of the subscriber, from `device_id` when known, and returns its member and how many older connections it pushed out."
  @spec join(Relay.Scope.t(), Relay.Id.t(), String.t() | nil) ::
          {:ok, member(), non_neg_integer()} | {:error, Relay.Error.t()}
  def join(scope, subscriber_id, device_id) when is_nil(device_id) or is_binary(device_id) do
    member = member(device_id)

    case Relay.Platform.connection_set_join(scope, path(subscriber_id), member, @ttl_ms, @max) do
      {:ok, {_count, evicted}} -> {:ok, member, evicted}
      {:error, _} = error -> error
    end
  end

  # IN-52
  @doc "Refreshes a connection's member; `:gone` when it was pushed out or expired."
  @spec touch(Relay.Scope.t(), Relay.Id.t(), member()) :: :ok | :gone | {:error, Relay.Error.t()}
  def touch(scope, subscriber_id, member),
    do: Relay.Platform.connection_set_touch(scope, path(subscriber_id), member, @ttl_ms)

  @doc "Removes a connection's member."
  @spec leave(Relay.Scope.t(), Relay.Id.t(), member()) :: :ok | {:error, Relay.Error.t()}
  def leave(scope, subscriber_id, member),
    do: Relay.Platform.connection_set_leave(scope, path(subscriber_id), member, @ttl_ms)

  # IN-40
  @doc "True when the subscriber has a live connection from `device_id`."
  @spec connected?(Relay.Scope.t(), Relay.Id.t(), String.t()) :: boolean()
  def connected?(scope, subscriber_id, device_id) do
    device?(device_id) and
      Relay.Platform.connection_set_any_suffix?(
        scope,
        path(subscriber_id),
        ":" <> device_id,
        @ttl_ms
      ) == {:ok, true}
  end

  defp member(device_id) do
    at = Relay.Clock.utc_now() |> DateTime.to_unix(:millisecond) |> Integer.to_string()
    id = Base.encode16(Relay.Random.bytes(8), case: :lower)
    String.pad_leading(at, 15, "0") <> ":" <> id <> ":" <> (device_id || @none)
  end

  defp path(subscriber_id), do: ["realtime", "connections", Relay.Id.to_string(subscriber_id)]
end
