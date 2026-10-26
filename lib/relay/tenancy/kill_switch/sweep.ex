defmodule Relay.Tenancy.KillSwitch.Sweep do
  @moduledoc """
  The queue stop point of a kill switch (TN-40 (2), S-49): the job the engaging transaction inserts pauses, batch by batch, the pending deliveries the new record matches in channel, message class, sub-tenant and provider account; a platform record's job visits every scope with pending deliveries. The other dimensions are caught by the first step of each delivery job. A job that runs out of its batch budget snoozes and continues.

  Telemetry: `[:relay, :kill_switch, :sweep]` (`paused`) for the time-to-stop SLO (TN-44).
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 20, timeout: 300_000

  alias Relay.Tenancy.KillSwitch

  # TN-40
  # TN-44
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kill_switch_id" => id, "platform" => platform?} = args}) do
    {:ok, scope} = Relay.Scope.from_job_args(args)
    {:ok, kill_switch_id} = Relay.Id.parse(id)

    {paused, more?} =
      scope
      |> KillSwitch.sweep_scopes(kill_switch_id, platform?)
      |> Enum.reduce({0, false}, fn target, {total, more?} ->
        {paused, left?} = KillSwitch.sweep(target, kill_switch_id)
        {total + paused, more? or left?}
      end)

    :telemetry.execute([:relay, :kill_switch, :sweep], %{paused: paused}, %{platform: platform?})

    if more?, do: {:snooze, 1}, else: :ok
  end
end
