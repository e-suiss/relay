defmodule Relay.Delivery.ReportTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery.Ledger
  alias Relay.Platform.Store
  alias RelayTest.DeliveryFixture

  defp today, do: Relay.Clock.utc_now() |> DateTime.to_date()
  defp tomorrow, do: Date.add(today(), 1)

  defp engagement!(scope, delivery_id, event_type, actor, detail) do
    entry =
      struct!(Ledger,
        id: Relay.Id.generate(),
        delivery_id: delivery_id,
        actor: actor,
        event_type: event_type,
        occurred_at: Relay.Clock.utc_now(),
        detail: detail
      )

    {:ok, [_row]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.ledger_append", Ledger.params(entry))
      end)
  end

  defp delivered!(opts \\ []) do
    %{scope: scope, delivery_id: id} = fixture = DeliveryFixture.sendable!(opts)
    n = DeliveryFixture.started_attempt!(scope, id)
    DeliveryFixture.finish(scope, id, n, :succeeded, delivery_rank: 2)
    fixture
  end

  defp report(scope, kind) do
    {:ok, rows} = Relay.Delivery.report(scope, kind, today(), tomorrow())
    rows
  end

  describe "DS-35 DS-36 rollup reports" do
    test "DS-36, DS-35: the funnel and engagement of a day are recomputed from the ledger" do
      %{scope: scope, delivery_id: id} = delivered!()
      engagement!(scope, id, "engagement.clicked", :user, %{"class" => "human"})
      engagement!(scope, id, "engagement.clicked", :relay, %{"class" => "likely_bot"})
      engagement!(scope, id, "engagement.opened", :relay, %{"machine_open" => true})
      engagement!(scope, id, "engagement.opened", :relay, %{"machine_open" => false})

      assert {:ok, %{deliveries: 1, skips: 0}} =
               Relay.Delivery.recompute_report_day(scope, today())

      assert [row] = report(scope, :deliveries)

      assert %{
               "channel" => "email",
               "is_test" => false,
               "accepted" => 1,
               "enqueued" => 1,
               "dispatched" => 1,
               "provider_accepted" => 1,
               "delivered" => 1,
               "engaged" => 1,
               "human_clicks" => 1,
               "bot_clicks" => 1,
               "opens" => 1,
               "machine_opens" => 1,
               "skipped" => 0,
               "failed" => 0
             } = row
    end

    test "DS-35: recomputing a day again gives the same counts" do
      %{scope: scope} = delivered!()
      {:ok, _first} = Relay.Delivery.recompute_report_day(scope, today())
      first = Enum.map(report(scope, :deliveries), &Map.delete(&1, "recomputed_at"))
      {:ok, _again} = Relay.Delivery.recompute_report_day(scope, today())
      assert Enum.map(report(scope, :deliveries), &Map.delete(&1, "recomputed_at")) == first
    end

    test "DS-35, DS-24: skips are counted by reason and rule" do
      delivery = [decision: :skip, decision_reason: "test", decision_rule_id: "TEST-1"]
      %{scope: scope} = DeliveryFixture.sendable!(delivery: delivery)
      assert {:ok, %{skips: 1}} = Relay.Delivery.recompute_report_day(scope, today())

      assert [%{"reason" => "test", "rule_id" => "TEST-1", "skipped" => 1}] =
               report(scope, :skips)

      assert [%{"accepted" => 1, "enqueued" => 0, "skipped" => 1}] = report(scope, :deliveries)
    end

    test "DS-35: test sends are their own rows" do
      %{scope: scope} = delivered!(notification: [is_test: true])
      {:ok, _counts} = Relay.Delivery.recompute_report_day(scope, today())
      assert [%{"is_test" => true, "delivered" => 1}] = report(scope, :deliveries)
    end
  end

  describe "TN-18 report isolation" do
    test "TN-18: a tenant's report holds only its own rows" do
      %{scope: mine} = delivered!()
      %{scope: theirs} = delivered!()
      {:ok, _mine} = Relay.Delivery.recompute_report_day(mine, today())
      {:ok, _theirs} = Relay.Delivery.recompute_report_day(theirs, today())

      assert [%{"accepted" => 1}] = report(mine, :deliveries)
      assert [%{"accepted" => 1}] = report(theirs, :deliveries)
      assert report(%{mine | environment: :test}, :deliveries) == []
    end

    test "TN-18, OP-39: the report role reads under row level security and writes nothing" do
      %{rows: [[super?, bypass?]]} =
        Relay.Repo.query!(
          "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = 'relay_report'",
          []
        )

      refute super?
      refute bypass?

      %{rows: [[writable, unsecured]]} =
        Relay.Repo.query!(
          """
          SELECT count(*) FILTER (WHERE has_table_privilege('relay_report', c.oid,
              'INSERT, UPDATE, DELETE, TRUNCATE')),
            count(*) FILTER (WHERE has_table_privilege('relay_report', c.oid, 'SELECT')
              AND c.relname LIKE 'report\\_%' AND NOT (c.relrowsecurity AND c.relforcerowsecurity))
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p')
          """,
          []
        )

      assert writable == 0
      assert unsecured == 0
    end

    test "TN-18, TN-14: the report pool must log in as relay_report and write nothing" do
      facts = %{
        roles: [{"relay_report", false, false}],
        owned: [],
        tables: [{"relay", "report_delivery_rollups", ["SELECT"]}],
        schemas: [{"relay", true}],
        current_user: "relay_report",
        session_user: "relay_report",
        server_version_num: 180_001,
        server_version: "18.1",
        row_security: "on",
        statement_timeout_ms: 300_000,
        context_settings: []
      }

      assert :ok = Store.evaluate(facts, :report)

      writes = %{facts | tables: [{"relay", "usage_records", ["SELECT", "INSERT"]}]}
      assert {:error, %{details: %{violations: found}}} = Store.evaluate(writes, :report)
      assert :writes_record_tables in found

      worker = %{facts | session_user: "relay_worker", current_user: "relay_worker"}
      assert {:error, %{details: %{violations: found}}} = Store.evaluate(worker, :report)
      assert :wrong_login_role in found
    end

    test "TN-18: platform metrics carry no personal or record identifier label" do
      personal =
        ~w(recipient_id subscriber_id external_id address email phone ip user_agent device_token
           notification_id delivery_id event_id tenant_name)a

      for metric <- RelayWeb.Telemetry.metrics(), tag <- metric.tags do
        refute tag in personal, "#{inspect(metric.name)} is labelled by #{tag}"
      end
    end
  end
end
