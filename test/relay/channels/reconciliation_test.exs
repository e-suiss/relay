defmodule Relay.Channels.ReconciliationTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live.ReceiptWorker
  alias Relay.Channels.Live.Reconciliation
  alias Relay.Datasets
  alias RelayTest.DeliveryFixture
  alias RelayTest.IngestFixture
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "email_bounce_codes", "reconciliation"]
  @receipts "Relay.Channels.Live.ReceiptWorker"

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

  defp settings do
    %{
      "status" => %{"interval_s" => 900, "per_round" => 500, "min_age_s" => %{"sms" => -3600}},
      "report" => %{"run_at" => "03:30"},
      "providers" => []
    }
  end

  defp credential!(scope, value) do
    var = "RELAY_TEST_RECONCILE_" <> String.upcase(TenantFixture.random())
    System.put_env(var, Jason.encode!(value))
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: :provider_credential,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    id
  end

  defp account!(scope, provider, channel, settings, credential) do
    attrs = %{
      id: Relay.Id.generate(),
      channel: channel,
      provider: provider,
      ownership: "tenant",
      credential_ref_id: credential,
      role: "primary",
      priority: 0,
      in_installation: true,
      transfer_basis: "none",
      settings: settings
    }

    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, attrs, digest, actor)

    {:ok, :changed} =
      Relay.Channels.verify_account(scope, attrs.id, "verified", nil, digest, actor)

    attrs.id
  end

  defp accepted!(scope, delivery_id, account_id) do
    {:ok, {:opened, n}} =
      Relay.Delivery.open_attempt(scope, %{
        id: Relay.Id.generate(),
        delivery_id: delivery_id,
        provider: "verimor",
        provider_account_id: account_id,
        provider_idempotency_key: "dlv-" <> Relay.Id.to_string(delivery_id)
      })

    {:ok, :started} = Relay.Delivery.start_attempt(scope, delivery_id, n)
    DeliveryFixture.finish(scope, delivery_id, n, :succeeded, delivery_rank: 1)
  end

  defp run_receipts(scope) do
    for [text] <- IngestFixture.jobs(@receipts, scope, "receipt_ids") do
      args = Map.put(Relay.Scope.to_job_args(scope), "receipt_ids", Jason.decode!(text))
      :ok = ReceiptWorker.perform(%Oban.Job{args: args})
    end
  end

  defp reported(scope, delivery_id) do
    {:ok, ledger} = Relay.Delivery.ledger(scope, delivery_id)
    Enum.filter(ledger, &(&1["event_type"] == "provider.reported"))
  end

  defp jobs_of(delivery_id) do
    sql = "SELECT count(*) FROM relay_queue.oban_jobs WHERE args->>'delivery_id' = $1"
    Relay.Repo.query!(sql, [Relay.Id.to_string(delivery_id)]).rows
  end

  defp verimor(conn, status) do
    Plug.Conn.send_resp(conn, 200, Jason.encode!([%{"message_id" => 5, "status" => status}]))
  end

  defp page(conn, delivery_id) do
    items =
      case conn.request_path do
        "/v3/mg.example.com/events" -> [delivered(delivery_id)]
        _next -> []
      end

    next = "https://api.mailgun.net/v3/mg.example.com/events/page-2"
    body = Jason.encode!(%{"items" => items, "paging" => %{"next" => next}})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp delivered(delivery_id) do
    %{
      "event" => "delivered",
      "id" => "ev-1",
      "timestamp" => DateTime.to_unix(Relay.Clock.utc_now()),
      "recipient" => "someone@example.com",
      "user-variables" => %{"relay_delivery_id" => Relay.Id.to_string(delivery_id)}
    }
  end

  describe "DS-48 sweep schedule" do
    test "DS-48: a status round is due every interval and a report round at run_at UTC" do
      settings = settings()

      assert Reconciliation.due_modes(settings, ~U[2026-11-11 10:00:00Z]) == ["status"]
      assert Reconciliation.due_modes(settings, ~U[2026-11-11 10:05:00Z]) == []
      assert Reconciliation.due_modes(settings, ~U[2026-11-11 10:15:00Z]) == ["status"]
      assert Reconciliation.due_modes(settings, ~U[2026-11-11 03:30:00Z]) == ["status", "report"]
      assert Reconciliation.due_modes(settings, ~U[2026-11-11 03:35:00Z]) == []
    end

    test "DS-48: the bundled reconciliation version names the reconciled providers" do
      assert {:ok, %{"status" => %{"interval_s" => 900, "per_round" => 500}} = content} =
               Reconciliation.settings()

      assert %{"provider" => "verimor", "mode" => "status"} in content["providers"]
      providers = content["providers"]
      assert %{"provider" => "mailgun", "channel" => "email", "mode" => "report"} in providers
    end
  end

  describe "DS-22 DS-48 INV-9 channel reconciliation" do
    test "DS-22, DS-48, INV-9: a status round records a provider's not delivered answer as provider_api and resends nothing" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!(delivery: [channel: :sms])
      credential = credential!(scope, %{"password" => "p"})
      account = account!(scope, "verimor", "sms", %{"username" => "u"}, credential)
      accepted!(scope, id, account)

      Req.Test.stub(Relay.Channels.ProviderHttp, &verimor(&1, "NOT_ALLOWED_BY_IYS"))

      assert {:ok, %{checked: 1, found: 1, recorded: 1, duplicates: 0}} =
               Reconciliation.status_round(scope, "verimor", "sms", settings())

      jobs = jobs_of(id)
      run_receipts(scope)

      assert [%{"actor" => "provider_api"}] = reported(scope, id)
      assert {:ok, %{"failure_kind" => "failed"}} = Relay.Delivery.delivery(scope, id)
      assert jobs_of(id) == jobs

      assert {:ok, %{checked: 0}} =
               Reconciliation.status_round(scope, "verimor", "sms", settings())
    end

    test "DS-48, DS-22: a pending status answer records nothing and keeps the delivery open" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!(delivery: [channel: :sms])
      credential = credential!(scope, %{"password" => "p"})
      account = account!(scope, "verimor", "sms", %{"username" => "u"}, credential)
      accepted!(scope, id, account)

      Req.Test.stub(Relay.Channels.ProviderHttp, &verimor(&1, "WAITING"))

      assert {:ok, %{checked: 1, found: 0, recorded: 0}} =
               Reconciliation.status_round(scope, "verimor", "sms", settings())

      assert reported(scope, id) == []
      assert {:ok, %{"delivery_rank" => 1}} = Relay.Delivery.delivery(scope, id)
    end

    test "DS-48, DS-22, INV-12: a report round reads the previous day's events once and counts the known ones" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      credential = credential!(scope, %{"api_key" => "key-1"})
      streams = %{"streams" => %{"transactional" => %{"domain" => "mg.example.com"}}}
      account!(scope, "mailgun", "email", streams, credential)
      day = ~D[2026-11-10]

      Req.Test.stub(Relay.Channels.Email.Esp, &page(&1, id))

      assert {:ok, %{found: 1, recorded: 1, duplicates: 0}} =
               Reconciliation.report_round(scope, "mailgun", "email", day)

      assert {:ok, %{found: 1, recorded: 0, duplicates: 1}} =
               Reconciliation.report_round(scope, "mailgun", "email", day)

      run_receipts(scope)
      assert [%{"actor" => "provider_api"}] = reported(scope, id)
      assert {:ok, %{"delivery_rank" => 2}} = Relay.Delivery.delivery(scope, id)
    end
  end
end
