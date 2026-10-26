defmodule Relay.Platform.LoadShed.Controller do
  @moduledoc """
  The `load_shed_controller` singleton task: once a second, on the one worker node holding its lease, it samples every lane's queue delay and records load shedding transitions (`Relay.Platform.load_shed_step/2`). The lane timers are the task state, so a new leader continues them; a transition written under a stale fencing token is refused.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  @loop_ms 1_000

  # T-34 (1)
  # T-12
  @impl Relay.Platform.Leadership
  @doc "Runs one controller step."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{fencing_token: token, state: saved}) do
    with {:ok, state} <- Relay.Platform.load_shed_step(token, saved), do: {:ok, state, @loop_ms}
  end
end
