defmodule Relay.InvariantsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    %{tenant: tenant, keys: keys, recipient: TenantFixture.recipient!(tenant.live, keys)}
  end

  defp accept(ctx, opts) do
    Relay.Ingest.accept(
      ctx.tenant.live,
      TenantFixture.accept_request(
        [TenantFixture.notification(ctx.recipient, Keyword.get(opts, :notification, []))],
        Keyword.merge([data_key: ctx.keys.data], opts)
      )
    )
  end

  defp constraint(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT contype::text, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1 AND connamespace = 'relay'::regnamespace",
        [name]
      )

    rows
  end

  describe "INV-11 every changing request is replay-protected" do
    test "INV-11: the same key with another body never returns the stored response", ctx do
      key = "key-" <> TenantFixture.random()
      assert {:ok, %{response: {202, _, _}}} = accept(ctx, key: key, body: "first")

      for body <- ["second", "first "] do
        assert {:error, %Relay.Error{code: :idempotency_conflict, details: %{status: 422}}} =
                 accept(ctx, key: key, body: body)
      end

      assert {:ok, %{replayed: %{status: 202}}} = accept(ctx, key: key, body: "first")
    end

    test "INV-11: a request without a usable key is refused with 400" do
      for key <- [nil, "", "short"] do
        assert {:error, %Relay.Error{details: %{status: 400}}} =
                 Relay.Ingest.Idempotency.parse_key(key)
      end
    end

    test "INV-11: the idempotency record is durable in PostgreSQL", ctx do
      key = "key-" <> TenantFixture.random()
      {:ok, _} = accept(ctx, key: key, body: "durable")

      %{rows: [[persistence]]} =
        Repo.query!(
          "SELECT relpersistence::text FROM pg_class WHERE oid = 'relay.idempotency_keys'::regclass",
          []
        )

      assert persistence == "p"
      assert {:ok, %{replayed: %{status: 202}}} = accept(ctx, key: key, body: "durable")
    end
  end

  describe "INV-12 T-16 exact uniqueness lives in database constraints" do
    test "INV-12: dedup key, delivery, provider receipt and idempotency key are UNIQUE constraints" do
      for {name, columns} <- [
            {"notifications_dedup_key_key", "(tenant_id, environment, dedup_key, recipient_id)"},
            {"deliveries_target_key",
             "(tenant_id, environment, notification_id, channel, target_key)"},
            {"webhook_receipts_provider_event_id_key",
             "(tenant_id, environment, provider, provider_event_id)"}
          ] do
        assert [["u", definition]] = constraint(name)
        assert definition == "UNIQUE " <> columns
      end
    end

    test "T-16: a repeated dedup key is stopped by the constraint, not by the queue", ctx do
      assert {:ok, %{notifications: [%{result: :created, id: first}]}} =
               accept(ctx, notification: [dedup_key: "order-9"])

      assert {:ok, %{notifications: [%{result: :duplicate, id: ^first}]}} =
               accept(ctx, notification: [dedup_key: "order-9"])
    end

    test "T-16: no queue worker relies on queue uniqueness" do
      {:ok, modules} = :application.get_key(:relay, :modules)

      behaviours = fn module ->
        module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
      end

      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__opts__, 0),
          Oban.Worker in behaviours.(module) do
        refute Keyword.has_key?(module.__opts__(), :unique), "#{inspect(module)} uses unique"
      end
    end
  end

  describe "INV-50 one authority for time" do
    test "INV-50: every timestamp column of the relay schema is timestamptz" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'relay' AND data_type IN ('timestamp without time zone', 'time without time zone', 'time with time zone')",
          []
        )

      assert rows == []
    end

    test "INV-50: timestamps come back as UTC whatever the session time zone" do
      {:ok, value} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL TimeZone = 'Asia/Tehran'", [])
          %{rows: [[value]]} = Repo.query!("SELECT '2026-10-23 12:00:00+00'::timestamptz", [])
          value
        end)

      assert value == ~U[2026-10-23 12:00:00.000000Z]
    end

    test "INV-50: the bundled tzdata is the only time zone source and never updates itself" do
      deps = Mix.Dep.Lock.read() |> Map.keys()
      assert :tzdata in deps
      refute Enum.any?([:tz, :tz_world, :timex, :zoneinfo], &(&1 in deps))
      assert Application.get_env(:elixir, :time_zone_database) == Tzdata.TimeZoneDatabase
      assert Application.get_env(:tzdata, :autoupdate) == :disabled
    end
  end

  describe "X-24 live and test are separate data planes" do
    test "X-24: the test environment of a tenant never sees its live data", ctx do
      {:ok, %{notifications: [%{id: id}]}} = accept(ctx, [])
      assert {:ok, %{"id" => ^id}} = Relay.Delivery.notification(ctx.tenant.live, id)
      assert {:ok, nil} = Relay.Delivery.notification(ctx.tenant.test, id)

      {:ok, rows} =
        Repo.in_scope(ctx.tenant.test, fn _ ->
          Repo.scoped_query!("SELECT tenant_id, environment FROM relay.notifications", []).rows
        end)

      assert rows == []
    end

    test "X-24: the environment belongs to the scope, never to the request body", ctx do
      request = TenantFixture.accept_request([TenantFixture.notification(ctx.recipient)])
      refute Map.has_key?(request, :environment)
      refute Enum.any?(request.notifications, &Map.has_key?(&1, :environment))
      assert {:error, %Relay.Error{}} = Relay.Scope.new(ctx.tenant.id, nil)
      assert {:error, %Relay.Error{}} = Relay.Scope.new(ctx.tenant.id, "staging")
    end
  end

  describe "INV-55 no network call inside a transaction" do
    test "INV-55: Valkey, the key store and signals raise inside a transaction", ctx do
      {:ok, topic} =
        Relay.Platform.signal_topic(Relay.Scope.tenant_text(ctx.tenant.live), "live", ["x"])

      Repo.transaction(fn ->
        assert_raise Relay.NetworkGuard.Error, ~r/:valkey/, fn ->
          Relay.Platform.publish_signal(topic, 1)
        end

        assert_raise Relay.NetworkGuard.Error, ~r/:keys/, fn -> Relay.Keys.ping() end
        assert_raise Relay.NetworkGuard.Error, fn -> Relay.NetworkGuard.check!(:http) end
      end)

      assert Relay.NetworkGuard.check!(:http) == :ok
    end

    test "INV-55: a scoped transaction is a transaction for the guard", ctx do
      {:ok, raised?} =
        Repo.in_scope(ctx.tenant.live, fn _ ->
          try do
            Relay.NetworkGuard.check!(:valkey)
            false
          rescue
            Relay.NetworkGuard.Error -> true
          end
        end)

      assert raised?
    end
  end
end
