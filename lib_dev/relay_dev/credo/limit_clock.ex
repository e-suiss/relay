defmodule RelayDev.Credo.LimitClock do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Limit, quota and lease decisions take their time from the deciding backend: Valkey `TIME` or PostgreSQL `clock_timestamp()` (T-11). The limiter modules listed in `.credo.exs` never read the node's wall clock; only durations use the node's monotonic clock.
      """
    ]

  @message "limit decisions use the backend's clock, never the node's wall clock (T-11)"

  # T-11
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {Relay.Clock, fun, _args} when fun in [:utc_now, :now, :business_now] -> @message
        {module, _fun, _args} when module in [DateTime, NaiveDateTime, Date, Time] -> @message
        _ -> nil
      end
    ])
  end
end
