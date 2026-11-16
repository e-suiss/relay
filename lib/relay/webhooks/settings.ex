defmodule Relay.Webhooks.Settings do
  @moduledoc """
  The values the delivery engine works with: the limits of the contract (`x-relay-limits` `webhook`, read through `Relay.Limits`) and the configuration of the installation (`config :relay, Relay.Webhooks`).

  The configuration names the engine's ports: `runtime: Module` (`Relay.Webhooks`, by default `Relay.Webhooks.Live`), `sealer: Module`, `destinations: %{kind => Module}`, an implementation of `Relay.Webhooks.Destination` that replaces the one `Relay.Webhooks.Destination.Kinds` names for an endpoint kind, and `destination_options: keyword` passed to every delivery. `source: url` is the `source` of Relay's own events, the installation issuer, and `operations_sender: address` the sender of operations e-mails (WH-56); neither has a default in code.
  """

  alias Relay.Limits
  alias Relay.Webhooks.Destination.Kinds
  alias Relay.Webhooks.RetrySchedule

  @jitter_bp 100 * Limits.fetch!(["webhook", "retry_schedule", "jitter_percent"])
  @max_deferrals Limits.fetch!(["webhook", "retry_after_max_deferrals"])
  @wait_max_ms 1000 * Limits.seconds!(["webhook", "retry_schedule", "wait", "max"])
  @payload_max Limits.fetch!(["webhook", "payload_max_bytes"])
  @connect_ms 1000 * Limits.seconds!(["webhook", "connect_timeout"])
  @request_ms 1000 * Limits.seconds!(["webhook", "request_timeout"])
  @response_max Limits.fetch!(["webhook", "response_body_max_bytes"])
  @concurrency Limits.fetch!(["webhook", "concurrency", "default"])
  @rate Limits.fetch!(["webhook", "rate_per_second", "default"])
  @health_window_s Limits.seconds!(["webhook", "health_window"])
  @retention %{
    messages_days: div(Limits.seconds!(["webhook", "retention", "messages"]), 86_400),
    response_body_days: div(Limits.seconds!(["webhook", "retention", "response_body"]), 86_400),
    min_days: div(Limits.seconds!(["webhook", "retention", "min"]), 86_400)
  }
  @health %{
    breaker: %{
      failure_threshold: Limits.fetch!(["webhook", "breaker", "failure_threshold"]),
      open_ms: 1000 * Limits.seconds!(["webhook", "breaker", "open"]),
      max_open_ms: 1000 * Limits.seconds!(["webhook", "breaker", "open_max"]),
      probe_ms: @request_ms + 5_000
    },
    start_within_ms: 1000 * Limits.seconds!(["webhook", "auto_disable", "start_failures_within"]),
    start_span_ms: 1000 * Limits.seconds!(["webhook", "auto_disable", "start_span"]),
    warn_after_ms: 1000 * Limits.seconds!(["webhook", "auto_disable", "warn_after"]),
    disable_after_ms: 1000 * Limits.seconds!(["webhook", "auto_disable", "after"])
  }
  @destination %{
    max_frame_bytes: Limits.fetch!(["webhook", "destination", "max_frame_bytes"]),
    ack_timeout_ms: 1000 * Limits.seconds!(["webhook", "destination", "ack_timeout"]),
    max_scram_iterations: Limits.fetch!(["webhook", "destination", "max_scram_iterations"]),
    assertion_ttl_s: Limits.seconds!(["webhook", "destination", "assertion_ttl"]),
    credential_ttl_s: Limits.seconds!(["webhook", "destination", "credential_ttl"])
  }

  # WH-22 (2)
  @doc "The jitter of a wait in basis points."
  @spec jitter_bp() :: 0..10_000
  def jitter_bp, do: @jitter_bp

  # WH-25
  @doc "How often a `Retry-After` may defer one message, and the longest deferral in milliseconds."
  @spec deferrals() :: %{max: non_neg_integer(), max_ms: pos_integer()}
  def deferrals, do: %{max: @max_deferrals, max_ms: @wait_max_ms}

  # WH-29
  @doc "The hard limit of a payload in bytes."
  @spec payload_max() :: pos_integer()
  def payload_max, do: @payload_max

  # WH-24
  @doc "The limits of one request: connect and total timeout in milliseconds and the bytes read of an answer."
  @spec request() :: %{
          connect_ms: pos_integer(),
          total_ms: pos_integer(),
          response_max: pos_integer()
        }
  def request, do: %{connect_ms: @connect_ms, total_ms: @request_ms, response_max: @response_max}

  # WH-38
  @doc "The default concurrency and rate per second of an endpoint."
  @spec isolation() :: %{concurrency: pos_integer(), rate: pos_integer()}
  def isolation, do: %{concurrency: @concurrency, rate: @rate}

  # WH-35
  # WH-36
  # WH-55
  @doc "The parameters of `Relay.Webhooks.Health`."
  @spec health() :: Relay.Webhooks.Health.params()
  def health, do: @health

  # WH-39
  @doc "The window of the health statistics in seconds."
  @spec health_window_s() :: pos_integer()
  def health_window_s, do: @health_window_s

  # WH-30
  # WH-52
  @doc "The retention of the delivery log in days: messages, answers and the lowest a tenant may set."
  @spec retention() :: %{
          messages_days: pos_integer(),
          response_body_days: pos_integer(),
          min_days: pos_integer()
        }
  def retention, do: @retention

  # WH-22
  @doc "The retry schedule of an endpoint in milliseconds: its own, or the schedule of the profile."
  @spec schedule(map()) :: RetrySchedule.t()
  def schedule(%{"retry_schedule" => [_first | _rest] = seconds}),
    do: Enum.map(seconds, &(&1 * 1000))

  def schedule(_endpoint), do: RetrySchedule.standard()

  # WH-28
  @doc "When the retry window of a schedule that starts at `from` ends: its longest run with jitter and the time its attempts may take."
  @spec window_ends_at(RetrySchedule.t(), DateTime.t()) :: DateTime.t()
  def window_ends_at(schedule, %DateTime{} = from) do
    window = RetrySchedule.longest_window_ms(schedule, @jitter_bp)
    DateTime.add(from, window + length(schedule) * @request_ms + 60_000, :millisecond)
  end

  # WH-17
  @doc "The destination implementation of an endpoint kind, or `:error` for a kind this installation does not deliver to."
  @spec destination(String.t()) :: {:ok, module()} | :error
  def destination(kind) do
    case config() |> Keyword.get(:destinations, %{}) |> Map.fetch(kind) do
      {:ok, module} -> {:ok, module}
      :error -> Kinds.module(kind)
    end
  end

  # WH-17
  @doc "The limits the destinations besides HTTPS are called with: the largest broker frame, the wait for a broker's acknowledgement, the most SCRAM iterations a broker may ask for, and the lifetime of a signed assertion and of a derived credential."
  @spec destination_limits() :: %{
          max_frame_bytes: pos_integer(),
          ack_timeout_ms: pos_integer(),
          max_scram_iterations: pos_integer(),
          assertion_ttl_s: pos_integer(),
          credential_ttl_s: pos_integer()
        }
  def destination_limits, do: @destination

  @doc "The options every delivery is made with."
  @spec destination_options() :: keyword()
  def destination_options, do: Keyword.get(config(), :destination_options, [])

  @doc "The runtime port."
  @spec runtime() :: module()
  def runtime, do: Keyword.get(config(), :runtime, Relay.Webhooks.Live)

  @doc "The sealer port."
  @spec sealer() :: module()
  def sealer, do: Keyword.get(config(), :sealer, Relay.Webhooks.Live)

  # WH-8
  @doc "The `source` of Relay's own events: the configured installation issuer, without a trailing slash."
  @spec source() :: String.t()
  def source do
    case Keyword.get(config(), :source) do
      source when is_binary(source) and source != "" -> String.trim_trailing(source, "/")
      _unset -> "urn:suiss:relay"
    end
  end

  # WH-56
  @doc "The configured sender of operations e-mails, or `nil`."
  @spec operations_sender() :: String.t() | nil
  def operations_sender do
    case Keyword.get(config(), :operations_sender) do
      sender when is_binary(sender) and sender != "" -> sender
      _unset -> nil
    end
  end

  defp config, do: Application.get_env(:relay, Relay.Webhooks, [])
end
