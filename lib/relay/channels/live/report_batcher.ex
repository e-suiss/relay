defmodule Relay.Channels.Live.ReportBatcher do
  @moduledoc """
  The delivery report batcher (T-41): a Broadway pipeline that writes a storm of provider reports in batches instead of one transaction per report. A receipt job (`Relay.Channels.Live.ReceiptWorker`) pushes its receipts into the pipeline and waits until each is acknowledged; the batcher groups the receipts of every job by scope, up to 100 receipts or 50 ms, and writes each group in one transaction (`Relay.Channels.Live.Receipts.process/2`). A failed group fails the receipts of every job in it, and those jobs are tried again by the job queue; the receipt keeps a repeat from being written twice. Broadway's own rate limiting is not used.

  The pipeline runs on the worker role; where it is not running, a job processes its receipts itself, as one batch.
  """

  use Broadway

  alias Broadway.Message
  alias Relay.Channels.Live.Receipts
  alias Relay.Channels.Live.ReportBatcher.Ack
  alias Relay.Channels.Live.ReportBatcher.Producer
  alias Relay.Scope

  @batch_size 100
  @batch_timeout_ms 50
  @wait_ms 45_000

  @doc "Starts the pipeline under its module name."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [module: {Producer, []}, concurrency: 1],
      processors: [default: [concurrency: 2]],
      batchers: [
        default: [concurrency: 4, batch_size: @batch_size, batch_timeout: @batch_timeout_ms]
      ]
    )
  end

  # T-41
  # WH-49
  @doc "Processes receipts of one scope through the pipeline and waits for them: `:ok` once every receipt is written, an error otherwise."
  @spec process(Scope.t(), [Relay.Id.t()]) :: :ok | {:error, term()}
  def process(%Scope{} = scope, receipt_ids) when is_list(receipt_ids) do
    if running?() do
      ref = make_ref()
      ack = {Ack, {self(), ref}, nil}
      messages = for id <- receipt_ids, do: %Message{data: {scope, id}, acknowledger: ack}
      :ok = Broadway.push_messages(__MODULE__, messages)
      await(ref, length(messages), 0)
    else
      Receipts.process(scope, receipt_ids)
    end
  end

  defp running? do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _none -> false
    end
  end

  defp await(_ref, 0, 0), do: :ok
  defp await(_ref, 0, failed), do: {:error, {:receipts_failed, failed}}

  defp await(ref, pending, failed) do
    receive do
      {^ref, done, bad} -> await(ref, max(pending - done - bad, 0), failed + bad)
    after
      @wait_ms -> {:error, :batcher_timeout}
    end
  end

  # T-41
  @impl Broadway
  def handle_message(_processor, %Message{data: {%Scope{} = scope, _id}} = message, _context),
    do: Message.put_batch_key(message, {scope.tenant_id, scope.environment})

  # T-41
  @impl Broadway
  def handle_batch(_batcher, [%Message{data: {scope, _id}} | _] = messages, _info, _context) do
    ids = Enum.map(messages, fn %Message{data: {_scope, id}} -> id end)

    case Receipts.process(scope, ids) do
      :ok -> messages
      {:error, reason} -> Enum.map(messages, &Message.failed(&1, reason))
    end
  end
end
