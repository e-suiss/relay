defmodule Relay.Clock do
  @moduledoc """
  Time port. Code reads wall-clock and monotonic time only through this module so that decisions are reproducible and the test plane can run a virtual clock.

  Business time (`business_now/1`) moves deadlines, heartbeats, escalations and future-dated work. In the `live` environment it is the system clock and nothing else; only a `test` scope reads its tenant's virtual clock offset, through `Relay.Clock.Virtual`. Rate limits, quotas, circuit breakers and backoff never use business time.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_ms() :: integer()

  # T-57
  # T-11
  @doc "Returns the current UTC time from the configured clock."
  @spec utc_now() :: DateTime.t()
  def utc_now, do: impl().utc_now()

  @doc "Returns monotonic time in milliseconds from the configured clock."
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: impl().monotonic_ms()

  # TN-8
  # X-27
  # T-57 (3)
  @doc "Returns business time for a scope: the system clock in `live`, the clock moved by the tenant's virtual offset in `test`."
  @spec business_now(Relay.Scope.t()) :: DateTime.t()
  def business_now(%Relay.Scope{environment: :live}), do: utc_now()
  def business_now(%Relay.Scope{environment: :test} = scope), do: Relay.Clock.Virtual.now(scope)

  # TN-8
  # T-24
  @doc "Converts a business time of a scope to the wall-clock time at which it falls due: unchanged in `live`, earlier by the virtual offset in `test`."
  @spec wall_time(Relay.Scope.t(), DateTime.t()) :: DateTime.t()
  def wall_time(%Relay.Scope{environment: :live}, %DateTime{} = at), do: at

  def wall_time(%Relay.Scope{environment: :test} = scope, %DateTime{} = at),
    do: Relay.Clock.Virtual.to_wall(scope, at)

  defp impl, do: Application.fetch_env!(:relay, :clock)
end
