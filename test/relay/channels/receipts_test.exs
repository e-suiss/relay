defmodule Relay.Channels.ReceiptsTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Channels.Live.ReceiptWorker
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.IngestFixture
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "email_bounce_codes"]
  @worker "Relay.Channels.Live.ReceiptWorker"

  defp forget do
    for name <- @datasets,
        do: Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    :ok
  end

  defp request(body, headers \\ [], token \\ nil) do
    %{
      body: body,
      headers: headers,
      url: "https://relay.test/inbound/v1/providers/x",
      token: token,
      now: Relay.Clock.utc_now()
    }
  end

  defp verimor(delivery_id, status) do
    Jason.encode!([
      %{
        "message_id" => 5,
        "status" => status,
        "message_custom_id" => "dlv-" <> Relay.Id.to_string(delivery_id)
      }
    ])
  end

  defp bounce(delivery_id) do
    Jason.encode!(%{
      "RecordType" => "Bounce",
      "Type" => "HardBounce",
      "ID" => 7,
      "MessageID" => "pm-1",
      "Email" => "bounced@example.com",
      "Details" => "smtp;550 5.1.1 user unknown",
      "BouncedAt" => "2026-11-05T10:00:00Z",
      "Metadata" => %{"relay_delivery_id" => Relay.Id.to_string(delivery_id)}
    })
  end

  defp account(provider), do: %{"id" => Relay.Id.generate(), "provider" => provider}

  defp jobs(scope) do
    for [text] <- IngestFixture.jobs(@worker, scope, "receipt_ids"), do: Jason.decode!(text)
  end

  defp run(scope, texts) do
    args = Map.put(Relay.Scope.to_job_args(scope), "receipt_ids", texts)
    ReceiptWorker.perform(%Oban.Job{args: args})
  end

  defp receipt(scope, text) do
    {:ok, id} = Relay.Id.parse(text)
    {:ok, row} = Relay.Repo.in_scope(scope, fn _status -> Relay.Webhooks.receipt(id) end)
    row
  end

  defp reported(scope, delivery_id) do
    {:ok, ledger} = Relay.Delivery.ledger(scope, delivery_id)
    Enum.filter(ledger, &(&1["event_type"] == "provider.reported"))
  end

  describe "WH-49 INV-12 T-41 provider webhook receipts" do
    test "WH-49, INV-12, DS-22: a verified report is committed once as a receipt and a repeat is counted" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      account = account("verimor")
      key = Relay.Redacted.wrap("token-1")
      request = request(verimor(id, "DELIVERED"), [], "token-1")

      assert {:ok, %{recorded: 1, duplicates: 0}} =
               Live.accept_provider_webhook(scope, account, key, request)

      assert {:ok, %{recorded: 0, duplicates: 1}} =
               Live.accept_provider_webhook(scope, account, key, request)

      assert [[text]] = jobs(scope)
      assert %{"state" => "received", "duplicate_count" => 1} = receipt(scope, text)
      assert reported(scope, id) == []

      assert {:error, :bad_signature} =
               Live.accept_provider_webhook(scope, account, key, %{request | token: "token-2"})
    end

    test "WH-49, T-41, DS-10: the receipt job writes the report to the ledger through the evidence table once" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      key = Relay.Redacted.wrap("token-1")
      request = request(verimor(id, "DELIVERED"), [], "token-1")
      {:ok, _counts} = Live.accept_provider_webhook(scope, account("verimor"), key, request)
      [[text]] = jobs(scope)

      assert :ok = run(scope, [text])
      assert %{"state" => "processed"} = receipt(scope, text)
      assert {:ok, %{"delivery_rank" => 2}} = Relay.Delivery.delivery(scope, id)
      assert [%{"actor" => "provider_webhook"}] = reported(scope, id)

      assert :ok = run(scope, [text])
      assert [_once] = reported(scope, id)
    end

    test "WH-49, L-17: a report of an unknown delivery is rejected and a pending one is no receipt" do
      %{scope: scope} = DeliveryFixture.sendable!()
      key = Relay.Redacted.wrap("token-1")
      unknown = request(verimor(Relay.Id.generate(), "DELIVERED"), [], "token-1")
      pending = request(verimor(Relay.Id.generate(), "WAITING"), [], "token-1")

      assert {:ok, %{recorded: 0}} =
               Live.accept_provider_webhook(scope, account("verimor"), key, pending)

      assert {:ok, %{recorded: 1}} =
               Live.accept_provider_webhook(scope, account("verimor"), key, unknown)

      [[text]] = jobs(scope)
      assert :ok = run(scope, [text])
      assert %{"state" => "rejected"} = receipt(scope, text)
    end

    test "WH-49, T-40, CH-40: a verified e-mail bounce suppresses its address once its batch is written" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      key = Relay.Redacted.wrap("user:secret")
      basic = [{"authorization", "Basic " <> Base.encode64("user:secret")}]
      body = bounce(id)

      assert {:error, :missing_header} =
               Live.accept_provider_webhook(scope, account("postmark"), key, request(body))

      wrong = [{"authorization", "Basic " <> Base.encode64("user:other")}]

      assert {:error, :bad_signature} =
               Live.accept_provider_webhook(scope, account("postmark"), key, request(body, wrong))

      assert {:ok, %{recorded: 1}} =
               Live.accept_provider_webhook(scope, account("postmark"), key, request(body, basic))

      [[text]] = jobs(scope)
      assert :ok = run(scope, [text])
      assert %{"state" => "processed"} = receipt(scope, text)
      assert {:ok, %{"failure_kind" => "bounced"}} = Relay.Delivery.delivery(scope, id)

      {:ok, rows} = Relay.Preferences.list_suppressions(scope, %{reason: "hard_bounce"}, nil, 10)
      assert [_suppression] = rows
    end
  end
end
