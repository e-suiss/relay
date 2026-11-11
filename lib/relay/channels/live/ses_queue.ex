defmodule Relay.Channels.Live.SesQueue do
  @moduledoc """
  The SES event queue reader (CH-47, WH-49): SES events reach Relay through the tenant's SQS queue, never through an HTTP subscription. Every minute on the `maintenance` queue, for each scope with a verified SES account (found through the discovery escape hatch, by identifiers only), each account with a `settings.ses.queue_url` is read: at most ten receives of up to ten messages each, with a one-second wait.

  Each message's SNS envelope is verified against the account's `settings.ses.topic_arn` (`Relay.Channels.ses_events/3`, T-40) and its SES events become receipts with their processing jobs through the same path as a webhook (`Relay.Channels.Live.Receipts.record/4`, `actor = provider_webhook`); the delivery report batcher writes them. A message is deleted from the queue only once its receipts are committed, so a failure leaves it to be received again, and a repeat is counted on its receipt. A message whose envelope does not verify can never be processed and is deleted.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 1, timeout: 240_000

  alias Relay.Channels.Live.Receipts
  alias Relay.Channels.Live.Store
  alias Relay.Scope

  @receives 10
  @scopes 1000
  @zero %{received: 0, recorded: 0, duplicates: 0, rejected: 0}

  @type counts :: %{
          received: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicates: non_neg_integer(),
          rejected: non_neg_integer()
        }

  # CH-47
  # TN-13 (4)
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for {tenant_id, environment} <- Store.reconciliation_scopes(["ses"], @scopes),
        {:ok, scope} <- [Scope.new(tenant_id, environment)],
        {:ok, accounts} <- [Store.in_scope(scope, &accounts/1)],
        account <- accounts,
        do: drain(scope, account)

    :ok
  end

  defp accounts(_status) do
    for %{"settings" => %{"ses" => %{"queue_url" => url}}} = account <-
          Store.reconciled_accounts("ses", "email"),
        is_binary(url),
        do: account
  end

  # CH-47
  # WH-49
  @doc "Reads the SQS event queue of one SES account (`id`, `provider`, `settings`, `credential_ref_id`) until it is empty or ten receives were made; options: `:fetch`, the SNS certificate reader, and `:wait_s` (1). Returns the counts of the messages received, the receipts recorded, the repeats and the rejected messages."
  @spec drain(Scope.t(), map(), keyword()) :: {:ok, counts()} | {:error, term()}
  def drain(%Scope{} = scope, account, opts \\ []) do
    with {:ok, credentials} <- credentials(scope, account) do
      {:ok, receive_loop(scope, account, credentials, opts, @receives, @zero)}
    end
  end

  defp receive_loop(_scope, _account, _credentials, _opts, 0, counts), do: counts

  defp receive_loop(scope, account, credentials, opts, left, counts) do
    wait_s = Keyword.get(opts, :wait_s, 1)

    case Relay.Channels.ses_receive(account, credentials, wait_s: wait_s) do
      {:ok, [_ | _] = messages} ->
        read = &message(scope, account, credentials, opts, &1, &2)
        counts = Enum.reduce(messages, counts, read)
        receive_loop(scope, account, credentials, opts, left - 1, counts)

      _empty_or_unavailable ->
        counts
    end
  end

  defp message(scope, account, credentials, opts, message, counts) do
    counts = %{counts | received: counts.received + 1}

    case events(account, to_string(message["Body"]), Keyword.get(opts, :fetch)) do
      {:ok, events} -> commit(scope, account, credentials, message, events, counts)
      {:error, _unverified} -> delete(account, credentials, message, bump(counts, :rejected, 1))
    end
  end

  defp events(account, body, nil), do: Relay.Channels.ses_events(account, body)
  defp events(account, body, fetch), do: Relay.Channels.ses_events(account, body, fetch)

  defp commit(scope, account, credentials, message, events, counts) do
    items =
      for %{delivery_id: <<_::128>>, type: type} = event <- events,
          type != :ignored,
          do: {:email, event}

    case Receipts.record(scope, account, items, :provider_webhook) do
      {:ok, %{recorded: recorded, duplicates: duplicates}} ->
        counts = counts |> bump(:recorded, recorded) |> bump(:duplicates, duplicates)
        delete(account, credentials, message, counts)

      {:error, _reason} ->
        counts
    end
  end

  defp delete(account, credentials, %{"ReceiptHandle" => handle}, counts)
       when is_binary(handle) do
    _ = Relay.Channels.ses_delete(account, credentials, handle)
    counts
  end

  defp delete(_account, _credentials, _message, counts), do: counts

  defp bump(counts, key, n), do: Map.update!(counts, key, &(&1 + n))

  # TN-26
  defp credentials(_scope, %{"credential_ref_id" => nil}), do: {:ok, nil}

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      {:error, _error} -> {:error, :credential_unavailable}
    end
  end
end
