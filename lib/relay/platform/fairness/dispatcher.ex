defmodule Relay.Platform.Fairness.Dispatcher do
  @moduledoc """
  The `drr_dispatcher` singleton task: once a second, on the one worker node holding its lease, it tops the `l2` and `l3` queues up from the tenant wait table with DRR rounds (`Relay.Platform.fair_dispatch_step/3`). Each round runs under the task's fencing token, so a former leader's round is refused; the round counters live in the task state in the database, and a change of leader costs at most one round of fairness.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Platform, Relay.Platform.Leadership],
    exports: []

  @behaviour Relay.Platform.Leadership

  @loop_ms 1_000

  # T-21 (2)
  # T-12
  # T-91 (1)
  @impl Relay.Platform.Leadership
  @doc "Runs one dispatcher step and returns the task state with the round counters the rounds saved."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{name: name, fencing_token: token, state: saved}) do
    weights_at = (saved || %{})["weights_at"]
    now_ms = DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)

    with {:ok, %{weights_at: weights_at}} <-
           Relay.Platform.fair_dispatch_step(token, weights_at, now_ms),
         {:ok, current} <- Relay.Platform.Leadership.saved_state(name) do
      {:ok, Map.put(current || %{}, "weights_at", weights_at), @loop_ms}
    end
  end
end
