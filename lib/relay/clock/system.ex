defmodule Relay.Clock.System do
  @moduledoc "System clock implementation of `Relay.Clock`."

  @behaviour Relay.Clock

  @impl true
  def utc_now, do: DateTime.utc_now(:microsecond)

  @impl true
  def monotonic_ms, do: System.monotonic_time(:millisecond)
end
