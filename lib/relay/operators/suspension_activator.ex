defmodule Relay.Operators.SuspensionActivator do
  @moduledoc """
  The `tenant_suspension_activator` singleton task: a suspension on other grounds is recorded `scheduled` and takes effect when its notice period ends (TN-71). Each step puts the due suspensions into effect; it runs every minute.
  """

  @behaviour Relay.Platform.Leadership

  @every_ms 60_000

  # TN-10
  # TN-71
  @impl Relay.Platform.Leadership
  @doc "Puts the due scheduled suspensions into effect."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    activated = Relay.Operators.Suspension.activate_due()
    {:ok, %{"activated" => activated}, @every_ms}
  end
end
