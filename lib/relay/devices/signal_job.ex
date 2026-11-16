defmodule Relay.Devices.SignalJob do
  @moduledoc """
  The job that sends one sync signal to the mobile devices of a subscriber (IN-35, IN-38, IN-52); see `Relay.Devices.Signals`. Its arguments carry the scope, the subscriber, the signal kind, the counter version and, for a read, the notification (T-15); a trailing signal of a coalescing window also names its device. A signal is a hint: a device that could not be reached is not retried.
  """

  use Relay.Worker, queue: :l1, max_attempts: 3, timeout: 60_000

  # IN-35
  # IN-38
  # T-15
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscriber_id" => subscriber} = args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, subscriber_id} <- Relay.Id.parse(subscriber),
         {:ok, _outcomes} <- Relay.Devices.run_signal(scope, subscriber_id, args) do
      :ok
    end
  end
end
