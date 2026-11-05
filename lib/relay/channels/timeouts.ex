defmodule Relay.Channels.Timeouts do
  @moduledoc """
  The three timeout layers of a provider call and the channel time to live (CH-9, L-13, WF-38, C-39). The message's `expires_at`, the channel's timeout and the provider call timeout all bound a call, and the one that ends first applies. The channel TTL of APNs `apns-expiration`, FCM `ttl`, Web Push `TTL` and the SMS validity period is `expires_at − now`. A provider's `Retry-After` is read as delta seconds or an HTTP date (RFC 9110); the wait the core plans from it is never shorter (`Relay.Delivery.RetryPolicy`).
  """

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # CH-9
  # WF-38
  # C-39
  @doc "The channel time to live in whole seconds, `expires_at − now` rounded down; `nil` without `expires_at` and `:expired` when nothing is left."
  @spec ttl_s(DateTime.t() | nil, DateTime.t()) :: pos_integer() | nil | :expired
  def ttl_s(nil, %DateTime{}), do: nil

  def ttl_s(%DateTime{} = expires_at, %DateTime{} = now) do
    case DateTime.diff(expires_at, now, :millisecond) do
      ms when ms >= 1000 -> div(ms, 1000)
      _left -> :expired
    end
  end

  # CH-9
  # L-13
  @doc "The timeout of a provider call: the shortest of the time left until `expires_at`, the channel timeout and the provider call timeout (`nil` is no bound at that layer); `:expired` when the message has no time left."
  @spec call_ms(DateTime.t() | nil, DateTime.t(), pos_integer() | nil, pos_integer()) ::
          {:ok, pos_integer()} | :expired
  def call_ms(expires_at, %DateTime{} = now, channel_ms, provider_ms)
      when is_integer(provider_ms) and provider_ms > 0 do
    left = if expires_at, do: DateTime.diff(expires_at, now, :millisecond)

    case Enum.min([provider_ms | Enum.reject([left, channel_ms], &is_nil/1)]) do
      ms when ms > 0 -> {:ok, ms}
      _none -> :expired
    end
  end

  # CH-9
  @doc "Parses a `Retry-After` value into milliseconds from `now`: delta seconds or an IMF-fixdate HTTP date; a date in the past is 0, anything else `nil`."
  @spec retry_after_ms(String.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def retry_after_ms(nil, %DateTime{}), do: nil

  def retry_after_ms(value, %DateTime{} = now) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> min(seconds, 86_400) * 1000
      _not_seconds -> date_ms(value, now)
    end
  end

  defp date_ms(value, now) do
    with [_day, day, month, year, time, "GMT"] <- String.split(value, " ", trim: true),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- date(year, index + 1, day),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      at |> DateTime.diff(now, :millisecond) |> max(0) |> min(86_400_000)
    else
      _invalid -> nil
    end
  end

  defp date(year, month, day) do
    with {y, ""} <- Integer.parse(year),
         {d, ""} <- Integer.parse(day) do
      Date.new(y, month, d)
    else
      _invalid -> :error
    end
  end
end
