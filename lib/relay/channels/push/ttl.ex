defmodule Relay.Channels.Push.Ttl do
  @moduledoc """
  Channel time to live derived from the message's `expires_at` and the current time (CH-9): the remaining usefulness, in whole seconds, rounded down. A message whose `expires_at` has passed is not sent. APNs takes the absolute expiry (`apns-expiration`, Unix seconds), FCM a duration of at most 28 days (`ttl`, `"<seconds>s"`) and Web Push a `TTL` in seconds, which Relay caps at the same 28 days.
  """

  @fcm_max 28 * 24 * 3600

  @type remaining :: {:ok, non_neg_integer()} | :expired | :none

  # CH-9
  @doc "The whole seconds left until `expires_at`; `:expired` when none are left, `:none` without an expiry."
  @spec remaining(DateTime.t() | nil, DateTime.t()) :: remaining()
  def remaining(nil, %DateTime{}), do: :none

  def remaining(%DateTime{} = expires_at, %DateTime{} = now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds > 0 -> {:ok, seconds}
      _passed -> :expired
    end
  end

  # CH-9
  @doc "The APNs `apns-expiration` value: the expiry in Unix seconds; `nil` (header left out) without an expiry."
  @spec apns_expiration(DateTime.t() | nil, DateTime.t()) ::
          {:ok, non_neg_integer() | nil} | :expired
  def apns_expiration(expires_at, now) do
    case remaining(expires_at, now) do
      {:ok, seconds} -> {:ok, DateTime.to_unix(now) + seconds}
      :none -> {:ok, nil}
      :expired -> :expired
    end
  end

  # CH-9
  @doc "The FCM `android.ttl` value, at most 28 days; without an expiry the FCM maximum."
  @spec fcm(DateTime.t() | nil, DateTime.t()) :: {:ok, String.t()} | :expired
  def fcm(expires_at, now) do
    with {:ok, seconds} <- seconds(expires_at, now), do: {:ok, "#{seconds}s"}
  end

  # CH-9
  @doc "The Web Push `TTL` value in seconds, at most 28 days; without an expiry the maximum."
  @spec web_push(DateTime.t() | nil, DateTime.t()) :: {:ok, non_neg_integer()} | :expired
  def web_push(expires_at, now), do: seconds(expires_at, now)

  defp seconds(expires_at, now) do
    case remaining(expires_at, now) do
      {:ok, seconds} -> {:ok, min(seconds, @fcm_max)}
      :none -> {:ok, @fcm_max}
      :expired -> :expired
    end
  end
end
