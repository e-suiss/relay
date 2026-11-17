defmodule Relay.Api.PayloadErasure do
  @moduledoc """
  The erasure of the stored data of an event that carried a secret (INV-22, INV-26, API-26, E-108): an OTP or verification message (`security_subtype`) or a message accepted with `retention: none`. The job is queued with the event in its acceptance transaction and carries only the scope, the event identifier and the reason (T-15). It clears the sealed data, links and overrides of the event through `Relay.Ingest.event_payload_erase/2` once every delivery of the event has left the pending state, and comes back every 30 seconds until then.
  """

  use Relay.Worker, queue: :l1, priority: 3, max_attempts: 20, timeout: 30_000

  @reasons ~w(security_subtype retention_none)
  @again_s 30

  # INV-22
  # INV-26
  # T-15
  @doc "Queues the erasure of an event's data inside the caller's scoped transaction."
  @spec enqueue(Relay.Scope.t(), Relay.Id.t(), String.t()) :: :ok | {:error, term()}
  def enqueue(%Relay.Scope{} = scope, <<_::128>> = event_id, reason) when reason in @reasons do
    erasure = %{"event_id" => Relay.Id.to_string(event_id), "reason" => reason}

    attrs = %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(:transactional),
      worker: __MODULE__,
      args: Map.merge(Relay.Scope.to_job_args(scope), erasure),
      ref_kind: "event_payload_erasure",
      ref_id: event_id,
      priority: 3
    }

    case Relay.Platform.enqueue_job(attrs) do
      {:ok, _queued} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # INV-22
  # INV-26
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => text, "reason" => reason} = args})
      when reason in @reasons do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, event_id} <- Relay.Id.parse(text) do
      erase = fn _status -> Relay.Ingest.event_payload_erase(event_id, reason) end

      case Relay.Ingest.in_event_scope(scope, erase) do
        {:ok, :not_terminal} -> {:snooze, @again_s}
        {:ok, _erased} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end
