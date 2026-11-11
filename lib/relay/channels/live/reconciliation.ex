defmodule Relay.Channels.Live.Reconciliation do
  @moduledoc """
  The periodic channel reconciliation (DS-22, DS-48, OP-42, L-17): a webhook is not a durable log, so Relay also asks the providers. What is reconciled, and how often, is the active version of the `reconciliation` data set (OP-65).

    * `status` providers (Verimor, Netgsm, Infobip): every `interval_s`, the open deliveries of each scope, channel and provider (accepted, neither delivered nor failed, older than the channel's `min_age_s`, at most `per_round`, oldest first) are asked about one by one through the adapter's status query (`c:Relay.Channels.Adapter.status/1`), with the latest attempt's idempotency key and provider message id.
    * `report` providers (Mailgun): once a day at `run_at` UTC, the provider's event list of every verified account is read for the previous UTC day (`c:Relay.Channels.Adapter.report_events/1`).

  Whatever the provider answers becomes items exactly like a webhook's and goes through the same durable receipts (`Relay.Channels.Live.Receipts.record/4`): the ledger entries carry `actor = provider_api` and follow the same evidence table and monotone rules, and an event the webhook already brought is a repeat, counted and not written again. A pending answer records nothing, so only the window rules apply to it. A "not delivered" answer is recorded as evidence and nothing else: reconciliation never resends and never falls back (INV-9, DS-21, OP-41).

  Each round is a count comparison: `found` provider events against the `duplicates` Relay already had; the difference, `recorded`, is the drift the webhooks missed. Telemetry: `[:relay, :reconciliation, :round]` with `checked`, `found`, `recorded`, `duplicates`, `unavailable` and `lag_ms` (the age of the oldest open delivery asked about), and `[:relay, :reconciliation, :drift]` with the drift `count` of a round that found any; both by `channel`, `provider` and `mode`.
  """

  require Logger

  alias Relay.Channels.Live.Receipts
  alias Relay.Channels.Live.ReconcileWorker
  alias Relay.Channels.Live.Store
  alias Relay.Scope

  @dataset "reconciliation"
  @sweep_s 300
  @scopes 1000
  @call_ms 5_000
  @no_target %{kind: :address, id: nil, value: Relay.Redacted.wrap("")}
  @zero %{checked: 0, found: 0, recorded: 0, duplicates: 0, unavailable: 0}

  @type counts :: %{
          checked: non_neg_integer(),
          found: non_neg_integer(),
          recorded: non_neg_integer(),
          duplicates: non_neg_integer(),
          unavailable: non_neg_integer()
        }

  # DS-48
  # OP-65 (4)
  @doc "The content of the active `reconciliation` version."
  @spec settings() :: {:ok, map()} | {:error, term()}
  def settings do
    case Relay.Datasets.decide(Relay.Datasets.installation_scope(), @dataset, & &1) do
      {:ok, {content, _ref}} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  # DS-48
  @doc "The modes whose round is due in the five-minute sweep that starts at `now`: `status` when `now` falls in the first sweep of an `interval_s` period, `report` when it falls in the sweep of `run_at`."
  @spec due_modes(map(), DateTime.t()) :: [String.t()]
  def due_modes(settings, %DateTime{} = now) do
    seconds = DateTime.to_unix(now)
    interval = settings["status"]["interval_s"]
    status? = rem(seconds, interval) < @sweep_s
    report? = within_run_at?(settings["report"]["run_at"], seconds)
    for {mode, true} <- [{"status", status?}, {"report", report?}], do: mode
  end

  defp within_run_at?(<<h::binary-2, ":", m::binary-2>>, seconds) do
    at = String.to_integer(h) * 3600 + String.to_integer(m) * 60
    of_day = rem(seconds, 86_400)
    of_day >= at and of_day < at + @sweep_s
  end

  defp within_run_at?(_run_at, _seconds), do: false

  # DS-48
  # TN-13 (4)
  @doc "Queues the reconciliation jobs whose round is due at `now`: one per scope and reconciled channel and provider of the due modes; answers how many were queued."
  @spec sweep(DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep(%DateTime{} = now) do
    with {:ok, settings} <- settings() do
      modes = due_modes(settings, now)
      entries = for %{"mode" => mode} = entry <- settings["providers"], mode in modes, do: entry
      day = now |> DateTime.to_date() |> Date.add(-1)

      jobs =
        for {tenant_id, environment} <- scopes(entries),
            {:ok, scope} <- [Scope.new(tenant_id, environment)],
            entry <- entries,
            do: ReconcileWorker.job(scope, entry, day)

      {:ok, Enum.count(jobs, &match?({:ok, _job}, Oban.insert(&1)))}
    end
  end

  defp scopes([]), do: []

  defp scopes(entries) do
    providers = entries |> Enum.map(& &1["provider"]) |> Enum.uniq()
    Store.reconciliation_scopes(providers, @scopes)
  end

  # DS-22
  # DS-48
  # INV-9
  @doc "Runs the status round of one scope, provider and channel with the data set's `settings`; see the module documentation."
  @spec status_round(Scope.t(), String.t(), String.t(), map()) ::
          {:ok, counts()} | {:error, term()}
  def status_round(%Scope{} = scope, provider, channel, settings) do
    status = settings["status"]
    min_age = Map.get(status["min_age_s"], channel, 0)
    read = fn _status -> Store.open_deliveries(provider, channel, min_age, status["per_round"]) end

    with {:ok, rows} <- Store.in_scope(scope, read) do
      counts =
        rows
        |> Enum.group_by(& &1["provider_account_id"])
        |> Enum.reduce(@zero, fn {account_id, deliveries}, acc ->
          add(acc, status_account(scope, account_id, deliveries))
        end)

      emit(counts, lag_ms(rows), %{channel: channel, provider: provider, mode: "status"})
      {:ok, counts}
    end
  end

  defp status_account(scope, account_id, deliveries) do
    with {:ok, %{} = account} <- Relay.Channels.provider_account(scope, account_id),
         {:ok, credentials} <- credentials(scope, account) do
      answers = Enum.map(deliveries, &ask(scope, account, credentials, &1))
      items = Enum.flat_map(answers, &items/1)
      asked = %{@zero | checked: length(deliveries)}
      commit(scope, account, items, %{asked | unavailable: Enum.count(answers, &(&1 == :unavailable))})
    else
      _unreadable -> %{@zero | checked: length(deliveries), unavailable: length(deliveries)}
    end
  end

  defp ask(scope, account, credentials, row) do
    request =
      Relay.Channels.request(%{
        scope: scope,
        delivery_id: row["id"],
        attempt_no: row["attempt_no"],
        channel: account["channel"],
        provider: account["provider"],
        idempotency_key: row["provider_idempotency_key"],
        provider_message_id: row["provider_message_id"],
        target: @no_target,
        timeout_ms: @call_ms,
        credentials: credentials,
        account: account
      })

    case Relay.Channels.reconcile_status(request) do
      {:ok, reports} -> {:reports, row["id"], reports}
      :not_received -> :not_received
      _unavailable -> :unavailable
    end
  end

  defp items({:reports, delivery_id, reports}) do
    key = "dlv-" <> Relay.Id.to_string(delivery_id)
    for %{result: result} = report <- reports,
        result != :pending,
        do: {:report, Map.put(report, :correlation, key)}
  end

  defp items(_answer), do: []

  # DS-22
  # DS-48
  @doc "Runs the report round of one scope, provider and channel for the UTC `day`: every verified account's event list of that day; see the module documentation."
  @spec report_round(Scope.t(), String.t(), String.t(), Date.t()) ::
          {:ok, counts()} | {:error, term()}
  def report_round(%Scope{} = scope, provider, channel, %Date{} = day) do
    from = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    to = DateTime.add(from, 86_400, :second)
    read = fn _status -> Store.reconciled_accounts(provider, channel) end

    with {:ok, accounts} <- Store.in_scope(scope, read) do
      counts =
        Enum.reduce(accounts, @zero, fn account, acc ->
          add(acc, report_account(scope, account, from, to))
        end)

      emit(counts, 0, %{channel: channel, provider: provider, mode: "report"})
      {:ok, counts}
    end
  end

  defp report_account(scope, account, from, to) do
    with {:ok, credentials} <- credentials(scope, account),
         {:ok, events} <- Relay.Channels.reconcile_events(account, credentials, from, to, @call_ms) do
      items =
        for %{delivery_id: <<_::128>>, type: type} = event <- events,
            type != :ignored,
            do: {:email, event}

      commit(scope, account, items, %{@zero | checked: 1})
    else
      _unavailable -> %{@zero | checked: 1, unavailable: 1}
    end
  end

  defp commit(scope, account, items, counts) do
    case Receipts.record(scope, account, items, :provider_api) do
      {:ok, %{recorded: recorded, duplicates: duplicates}} ->
        %{counts | found: length(items), recorded: recorded, duplicates: duplicates}

      {:error, _reason} ->
        %{counts | found: length(items), unavailable: counts.unavailable + 1}
    end
  end

  # TN-26
  defp credentials(_scope, %{"credential_ref_id" => nil}), do: {:ok, nil}

  defp credentials(scope, %{"credential_ref_id" => ref_id}) do
    case Relay.Secrets.fetch(scope, ref_id) do
      {:ok, secret} -> {:ok, secret}
      {:error, _error} -> {:error, :credential_unavailable}
    end
  end

  defp add(acc, counts), do: Map.merge(acc, counts, fn _key, a, b -> a + b end)

  defp lag_ms([%{"accepted_at" => %DateTime{} = at} | _rest]),
    do: max(DateTime.diff(Relay.Clock.utc_now(), at, :millisecond), 0)

  defp lag_ms(_rows), do: 0

  defp emit(counts, lag_ms, meta) do
    :telemetry.execute([:relay, :reconciliation, :round], Map.put(counts, :lag_ms, lag_ms), meta)

    if counts.recorded > 0 do
      :telemetry.execute([:relay, :reconciliation, :drift], %{count: counts.recorded}, meta)

      Logger.warning("reconciliation found provider events the webhooks missed",
        channel: meta.channel,
        provider: meta.provider,
        mode: meta.mode,
        count: counts.recorded
      )
    end
  end
end
