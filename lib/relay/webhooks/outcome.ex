defmodule Relay.Webhooks.Outcome do
  @moduledoc """
  Classifies the result of one delivery attempt into a decision (WH-18, WH-23, WH-26). A decision is data: nothing here raises, sleeps or touches a store, and a delivery that is not retried is a result, not an error.

  | Result of the attempt | Decision |
  |---|---|
  | HTTP 2xx, or a durable write acknowledged | `delivered` |
  | HTTP 410 | `failed_permanent` (`gone`), endpoint disabled now |
  | response header `webhook-delivery: abort-message` | `failed_permanent` (`aborted_by_consumer`) |
  | HTTP 3xx | `failed_permanent` (`redirect_not_followed`), health warning; never followed |
  | HTTP 401, 407, 409, 429, 5xx | retry |
  | any other 4xx | `failed_permanent` |
  | connection error, timeout, TLS error, DNS failure | retry |
  | destination not available, credentials not available | retry |
  | destination rejected the message | `dead_lettered` (`destination_rejected`) |
  | configuration invalid, address blocked | `dead_lettered`, no attempt was made |

  `retry_after_ms` is set only for 429 and 503 with a `Retry-After` header (WH-25); the retry schedule decides what to do with it. `breaker` is what the endpoint's circuit breaker is told: a success, a failure, or nothing when the endpoint answered on purpose or was never tried.

  The other terminal states of a message, `exhausted`, `expired`, `window_exceeded` and `cancelled`, are reached by the engine, not by one attempt (WH-27).
  """

  @enforce_keys [:result, :reason]
  defstruct [:result, :reason, :status, :retry_after_ms, endpoint: :none, breaker: :neutral]

  @type result :: :delivered | :retry | :failed_permanent | :dead_lettered
  @type state ::
          :delivered
          | :failed_permanent
          | :exhausted
          | :expired
          | :window_exceeded
          | :dead_lettered
          | :cancelled
  @type t :: %__MODULE__{
          result: result(),
          reason: atom(),
          status: non_neg_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          endpoint: :none | :warn | :disable,
          breaker: :success | :failure | :neutral
        }

  @states [
    :delivered,
    :failed_permanent,
    :exhausted,
    :expired,
    :window_exceeded,
    :dead_lettered,
    :cancelled
  ]
  @retried [401, 407, 409, 429]
  @deferrable [429, 503]
  @failures %{
    connect: {:retry, :connection_error, :failure, :none},
    dns: {:retry, :dns_error, :failure, :none},
    timeout: {:retry, :timeout, :failure, :none},
    tls: {:retry, :tls_error, :failure, :none},
    protocol: {:retry, :protocol_error, :failure, :none},
    unavailable: {:retry, :destination_unavailable, :failure, :none},
    credentials: {:retry, :credentials_unavailable, :neutral, :none},
    rejected: {:dead_lettered, :destination_rejected, :neutral, :none},
    invalid: {:dead_lettered, :destination_invalid, :neutral, :none},
    blocked: {:dead_lettered, :destination_blocked, :neutral, :warn}
  }
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @http_date ~r/\A[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
  @seconds ~r/\A[0-9]{1,9}\z/

  # WH-27
  @doc "The terminal states of a message."
  @spec terminal_states() :: [state(), ...]
  def terminal_states, do: @states

  # WH-27
  @doc "Whether a terminal state keeps the message in the dead letter queue: every terminal state but `delivered`."
  @spec dead_letter?(state()) :: boolean()
  def dead_letter?(state) when state in @states, do: state != :delivered

  # WH-18
  # WH-23
  # WH-26
  @doc "Classifies the result of one attempt, as a destination returned it. `now` is used to read a `Retry-After` given as a date."
  @spec classify({:ok, map()} | {:error, map()}, DateTime.t()) :: t()
  def classify({:ok, %{kind: :http, status: status} = receipt}, %DateTime{} = now)
      when is_integer(status) do
    headers = Map.get(receipt, :headers, [])
    %{http(status, headers, now) | status: status}
  end

  def classify({:ok, %{kind: :write}}, %DateTime{}),
    do: %__MODULE__{result: :delivered, reason: :acknowledged, breaker: :success}

  def classify({:error, %{class: class}}, %DateTime{}) when is_map_key(@failures, class) do
    {result, reason, breaker, endpoint} = Map.fetch!(@failures, class)
    %__MODULE__{result: result, reason: reason, breaker: breaker, endpoint: endpoint}
  end

  # WH-23
  defp http(status, _headers, _now) when status in 200..299,
    do: %__MODULE__{result: :delivered, reason: :accepted, breaker: :success}

  defp http(410, _headers, _now),
    do: %__MODULE__{result: :failed_permanent, reason: :gone, endpoint: :disable}

  defp http(status, headers, now) do
    if aborted?(headers),
      do: %__MODULE__{result: :failed_permanent, reason: :aborted_by_consumer},
      else: by_status(status, headers, now)
  end

  # WH-42 (3)
  defp by_status(status, _headers, _now) when status in 300..399,
    do: %__MODULE__{result: :failed_permanent, reason: :redirect_not_followed, endpoint: :warn}

  # WH-25
  defp by_status(status, headers, now) when status in @deferrable do
    retry = %__MODULE__{result: :retry, reason: :http_status, breaker: :failure}
    %{retry | retry_after_ms: retry_after_ms(headers, now)}
  end

  defp by_status(status, _headers, _now) when status in @retried or status in 500..599,
    do: %__MODULE__{result: :retry, reason: :http_status, breaker: :failure}

  defp by_status(status, _headers, _now) when status in 400..499,
    do: %__MODULE__{result: :failed_permanent, reason: :http_status}

  defp by_status(_status, _headers, _now),
    do: %__MODULE__{result: :retry, reason: :unexpected_status, breaker: :failure}

  # WH-26
  defp aborted?(headers) do
    Enum.any?(header(headers, "webhook-delivery"), fn value ->
      value |> String.trim() |> String.downcase(:ascii) == "abort-message"
    end)
  end

  # WH-25
  @doc "The `Retry-After` of response headers in milliseconds from `now`, given as seconds or as an HTTP date; `nil` when it is absent or not readable."
  @spec retry_after_ms([{String.t(), String.t()}], DateTime.t()) :: non_neg_integer() | nil
  def retry_after_ms(headers, %DateTime{} = now) when is_list(headers) do
    case header(headers, "retry-after") do
      [value | _rest] -> delay(String.trim(value), now)
      [] -> nil
    end
  end

  defp delay(value, now) do
    if Regex.match?(@seconds, value),
      do: String.to_integer(value) * 1000,
      else: from_date(http_date(value), now)
  end

  defp from_date(nil, _now), do: nil
  defp from_date(date, now), do: max(DateTime.diff(date, now, :millisecond), 0)

  defp http_date(value) do
    with [day, month, year, hour, minute, second] <- captures(value),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <- Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- time(hour, minute, second),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      at
    else
      _unreadable -> nil
    end
  end

  defp captures(value) do
    case Regex.run(@http_date, value, capture: :all_but_first) do
      nil -> []
      captures -> captures
    end
  end

  defp time(hour, minute, second),
    do: Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second))

  defp header(headers, name) do
    for {key, value} <- headers,
        is_binary(key),
        is_binary(value),
        String.downcase(key, :ascii) == name,
        do: value
  end
end
