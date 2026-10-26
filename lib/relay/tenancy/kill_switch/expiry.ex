defmodule Relay.Tenancy.KillSwitch.Expiry do
  @moduledoc """
  The `kill_switch_paused_expiry` singleton task: a paused delivery whose message expires is never sent; it closes as `expired` (TN-40). Each step visits every scope that holds paused deliveries and closes the expired ones; it runs every minute.
  """

  @behaviour Relay.Platform.Leadership

  @every_ms 60_000

  # TN-40
  @impl Relay.Platform.Leadership
  @doc "Closes the expired paused deliveries of every scope."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    expired = Relay.Tenancy.KillSwitch.expire_paused()
    {:ok, %{"expired" => expired}, @every_ms}
  end
end
