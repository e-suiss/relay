defmodule Relay.Clock do
  @moduledoc """
  Time port. Code reads wall-clock and monotonic time only through this module so that decisions are reproducible and the test plane can run a virtual clock.
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

  defp impl, do: Application.fetch_env!(:relay, :clock)
end
