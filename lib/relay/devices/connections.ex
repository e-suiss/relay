defmodule Relay.Devices.Connections do
  @moduledoc """
  The port to the realtime connection registry (IN-40): whether a device of a subscriber holds an active realtime connection. The answer comes from the registry's short-lived Valkey record and never from a synchronous query to the realtime layer. The registry is `config :relay, Relay.Devices, connections: Module`, by default `Relay.Realtime`, whose `connected?/3` is called; a registry that is not loaded, or an answer that is not `true`, is not connected, so a push is never held back on doubt.
  """

  @default Relay.Realtime

  @doc "Whether the device holds an active realtime connection."
  @callback connected?(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: boolean()

  # IN-40
  @doc "Asks the configured registry whether the device of `subscriber_id` holds an active realtime connection."
  @spec connected?(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: boolean()
  def connected?(%Relay.Scope{} = scope, subscriber_id, device_id) do
    module = registry()

    Code.ensure_loaded?(module) and function_exported?(module, :connected?, 3) and
      module.connected?(scope, subscriber_id, device_id) == true
  end

  defp registry do
    :relay |> Application.get_env(Relay.Devices, []) |> Keyword.get(:connections, @default)
  end
end
