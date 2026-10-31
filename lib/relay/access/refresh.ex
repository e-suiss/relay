defmodule Relay.Access.Refresh do
  @moduledoc """
  The `access_link_refresh` singleton task (E-78, S-68): every five minutes it fetches the Access discovery documents and key set and records them (`Relay.Access.Link.refresh/1`). A failed fetch leaves the link `stale` and is tried again on the next step.
  """

  @behaviour Relay.Platform.Leadership

  @every_s 300
  @step_ms 10_000

  # E-78
  # E-75
  @impl Relay.Platform.Leadership
  @doc "Refreshes the link when the last refresh is five minutes old."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: state}) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    case state do
      %{"at" => at} when is_integer(at) and now - at < @every_s ->
        {:ok, state, @step_ms}

      _due ->
        result = if match?({:ok, _}, Relay.Access.refresh()), do: "ok", else: "failed"
        {:ok, %{"at" => now, "result" => result}, @step_ms}
    end
  end
end
