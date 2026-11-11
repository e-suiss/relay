defmodule Relay.Channels.Live.ReceiptWorker do
  @moduledoc """
  The job that processes the receipts of one provider webhook request (WH-49): its arguments are the scope and at most 100 receipt identifiers (T-15). It hands them to the delivery report batcher (`Relay.Channels.Live.ReportBatcher`, T-41) and succeeds once every receipt of the job is written; a transient failure retries the job, and a receipt already processed is never processed again.
  """

  use Relay.Worker, queue: :l1, max_attempts: 20, timeout: 60_000

  alias Relay.Channels.Live.ReportBatcher
  alias Relay.Scope

  # T-15
  @doc "The arguments of a job of `receipt_ids` in `scope`."
  @spec args(Scope.t(), [Relay.Id.t(), ...]) :: map()
  def args(%Scope{} = scope, [_ | _] = receipt_ids) do
    scope
    |> Scope.to_job_args()
    |> Map.put("receipt_ids", Enum.map(receipt_ids, &Relay.Id.to_string/1))
  end

  # WH-49
  # T-41
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"receipt_ids" => [_ | _] = texts} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, receipt_ids} <- parse(texts) do
      ReportBatcher.process(scope, receipt_ids)
    else
      {:error, _invalid} -> {:cancel, :invalid_args}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp parse(texts) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case Relay.Id.parse(to_string(text)) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
