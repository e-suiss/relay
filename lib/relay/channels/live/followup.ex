defmodule Relay.Channels.Live.Followup do
  @moduledoc """
  The job that records a provider event reported later than the call, such as the fake provider's delayed delivery five minutes of virtual time after acceptance (CH-72, DS-23). Its arguments carry the scope, the delivery and the event code only (T-15); the event goes through `Relay.Channels.Live.Events.record/2`.
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 30_000

  alias Relay.Channels.Live.Events
  alias Relay.Scope

  # T-15
  @doc "The job changeset of an event recorded at `at`."
  @spec job(Scope.t(), Events.event(), DateTime.t()) :: Ecto.Changeset.t()
  def job(%Scope{} = scope, event, %DateTime{} = at) do
    scope
    |> Scope.to_job_args()
    |> Map.merge(%{
      "delivery_id" => Relay.Id.to_string(event.delivery_id),
      "provider" => event.provider,
      "channel" => event.channel,
      "event_code" => event.event_code
    })
    |> new(scheduled_at: at)
  end

  # DS-10
  # CH-72
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, delivery_id} <- Relay.Id.parse(delivery) do
      event = %{
        delivery_id: delivery_id,
        provider: args["provider"],
        channel: args["channel"],
        event_code: args["event_code"]
      }

      case Events.record(scope, event) do
        {:ok, _recorded} -> :ok
        {:error, reason} when reason in [:unknown_event, :delivery_not_found] -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
