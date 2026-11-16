defmodule Relay.Webhooks.NoticeWorker do
  @moduledoc """
  The job of one operations e-mail (WH-34, WH-36 (3), WH-39, WH-56): an exhausted delivery, a message whose window ended, an endpoint that has not answered for a while, an endpoint that was disabled. The e-mail goes to the tenant's operations contacts through the platform tenant's e-mail channel, from the sender the installation configured; there is no sender in code. Without a configured sender or without a contact the e-mail is skipped and recorded with the reason `operations_email_unavailable`; the webhook and panel notifications do not depend on it. The job's arguments carry identifiers only (T-15) and the e-mail names the endpoint by its identifier, never an address or a payload.

  Telemetry: `[:relay, :webhooks, :operations_email]` with `count`, tagged with the `kind` and the `result` (`sent`, `skipped` or `failed`) and, for a skip, the `reason`.
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 60_000

  alias Relay.Webhooks.Settings

  require Logger

  @subjects %{
    "attempt_exhausted" => "A webhook delivery used up its retries",
    "window_exceeded" => "A webhook delivery could not be made in its window",
    "endpoint_unresponsive" => "A webhook endpoint has not answered for 72 hours",
    "endpoint_disabled" => "A webhook endpoint was disabled"
  }

  # T-15
  # WH-56
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "endpoint_id" => endpoint_id} = args})
      when is_map_key(@subjects, kind) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(endpoint_id) do
      deliver(scope, kind, id)
    end
  end

  # WH-56
  @doc "Sends the operations e-mail of `kind` about an endpoint, or skips it; returns `:ok` for both and `{:error, reason}` when the e-mail could not be handed over."
  @spec deliver(Relay.Scope.t(), String.t(), Relay.Id.t()) :: :ok | {:error, term()}
  def deliver(scope, kind, endpoint_id) do
    sender = Settings.operations_sender()

    case Relay.Webhooks.contacts(scope) do
      {:ok, %{addresses: [_first | _rest] = addresses}} when is_binary(sender) ->
        subject = Map.fetch!(@subjects, kind)
        mail = %{from: sender, subject: subject, text: text(subject, endpoint_id)}
        sent(Settings.runtime().mail(scope, addresses, mail), kind)

      {:ok, _no_contact_or_sender} ->
        Logger.warning("operations e-mail skipped", reason: "operations_email_unavailable")
        measure(kind, %{result: :skipped, reason: :operations_email_unavailable})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sent(:ok, kind), do: measure(kind, %{result: :sent})

  defp sent({:error, reason}, kind) do
    measure(kind, %{result: :failed})
    {:error, reason}
  end

  defp measure(kind, meta) do
    :telemetry.execute(
      [:relay, :webhooks, :operations_email],
      %{count: 1},
      Map.put(meta, :kind, kind)
    )
  end

  defp text(subject, endpoint_id) do
    endpoint = Relay.ExternalId.encode("whe", endpoint_id)
    subject <> ".\n\nEndpoint: " <> endpoint <> "\n"
  end
end
