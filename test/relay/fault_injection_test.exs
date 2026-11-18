defmodule Relay.FaultInjectionTest do
  use Relay.DataCase, async: false

  alias Relay.FaultInjection
  alias Relay.FaultInjection.Evaluation
  alias Relay.FaultInjection.Record
  alias Relay.FaultInjection.Store
  alias Relay.Release.FaultInjection, as: Command
  alias RelayTest.TenantFixture

  @operator %{kind: :installation_operator, ref: "ops@example"}

  defp spec(fields \\ %{}) do
    Map.merge(
      %{
        scope_kind: :installation,
        environment: :test,
        kind: :rate_limited_429,
        rate_percent: 50,
        reason: "game day " <> TenantFixture.random(),
        ttl_seconds: 600
      },
      Map.new(fields)
    )
  end

  defp audit(action, target_id) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Relay.Repo.in_scope(Store.installation_scope(), fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    for row <- rows, row["target_id"] == Relay.Id.to_string(target_id) do
      {row["actor_kind"], row["actor_ref"], row["target_type"], row["reason"]}
    end
  end

  defp internal(external) do
    {:ok, id} = Relay.ExternalId.decode(external, ["fij"])
    id
  end

  defp record(fields) do
    struct!(
      Record,
      Map.merge(
        %{
          id: Relay.Id.generate(),
          scope_kind: :installation,
          scope_tenant_id: nil,
          target_environment: :test,
          channel: nil,
          provider: nil,
          kind: :provider_auth_error,
          rate_percent: 100,
          delay_ms: nil,
          status: :active,
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        },
        Map.new(fields)
      )
    )
  end

  defp point(fields \\ %{}) do
    Map.merge(
      %{tenant_id: Relay.Id.generate(), environment: :test, channel: "sms", provider: "fake"},
      Map.new(fields)
    )
  end

  describe "OP-92 records and their gates" do
    test "OP-92: a test environment injection is engaged with its audit record" do
      spec = spec(channel: "sms", provider: "fake")

      assert {:ok, %{result: :engaged, id: "fij_" <> _ = external}} =
               FaultInjection.engage(spec, @operator)

      assert {:ok, record} = FaultInjection.show(external)
      assert record.kind == :rate_limited_429
      assert record.rate_percent == 50
      assert record.channel == "sms" and record.provider == "fake"
      assert record.status == :active
      assert DateTime.diff(record.expires_at, record.created_at) == 600

      assert [{"installation_operator", "ops@example", "fault_injection", reason}] =
               audit("fault_injection.engaged", record.id)

      assert reason == spec.reason
    end

    test "OP-44: engaging the same dimensions twice answers the record in force" do
      spec = spec(kind: :concurrency_exhausted, rate_percent: 30)
      assert {:ok, %{result: :engaged, id: id}} = FaultInjection.engage(spec, @operator)
      assert {:ok, %{result: :exists, id: ^id}} = FaultInjection.engage(spec, @operator)
      assert length(audit("fault_injection.engaged", internal(id))) == 1
    end

    test "OP-92: a live injection is refused outside chaos mode and accepted in chaos mode" do
      live = spec(environment: :live, kind: :bounce_spike)

      assert FaultInjection.engage(live, @operator, chaos_mode: false) ==
               {:error, :not_permitted}

      assert {:ok, %{result: :engaged}} = FaultInjection.engage(live, @operator, chaos_mode: true)
    end

    test "OP-92: a TTL over one hour, a rate over 100 and a misplaced delay are refused" do
      assert FaultInjection.engage(spec(ttl_seconds: 3_601), @operator) == {:error, :invalid_ttl}
      assert FaultInjection.engage(spec(rate_percent: 101), @operator) == {:error, :invalid_rate}
      assert FaultInjection.engage(spec(delay_ms: 100), @operator) == {:error, :invalid_delay}

      assert FaultInjection.engage(spec(kind: :added_latency), @operator) ==
               {:error, :invalid_delay}

      assert FaultInjection.engage(spec(kind: :added_latency, delay_ms: 10_001), @operator) ==
               {:error, :invalid_delay}

      assert FaultInjection.engage(spec(kind: :iys_pull_stalled, channel: "sms"), @operator) ==
               {:error, :invalid_channel}

      assert FaultInjection.engage(spec(reason: " "), @operator) == {:error, :reason_required}

      assert FaultInjection.engage(spec(), %{kind: :tenant_admin, ref: "x"}) ==
               {:error, :installation_operator_required}
    end

    test "OP-44: clearing twice answers already_cleared and writes one audit record" do
      {:ok, %{id: id}} = FaultInjection.engage(spec(kind: :template_paused), @operator)

      assert {:ok, %{result: :cleared, id: ^id}} =
               FaultInjection.clear(id, "game day over", @operator)

      assert {:ok, %{result: :already_cleared}} =
               FaultInjection.clear(id, "game day over", @operator)

      assert [{_kind, _ref, "fault_injection", "game day over"}] =
               audit("fault_injection.cleared", internal(id))

      {:ok, records} = FaultInjection.list()
      refute Enum.any?(records, &(&1.id == internal(id)))
      {:ok, all} = FaultInjection.list(include_inactive: true)
      assert Enum.find(all, &(&1.id == internal(id))).status == :cleared
    end

    test "OP-92: the application role can neither change nor delete a fault injection" do
      {:ok, %{id: id}} = FaultInjection.engage(spec(kind: :bounce_spike), @operator)
      raw = internal(id)

      update = fn sql ->
        Relay.Repo.query("SAVEPOINT fi")
        result = Relay.Repo.query(sql, [raw])
        Relay.Repo.query("ROLLBACK TO SAVEPOINT fi")
        result
      end

      assert {:error, %Postgrex.Error{}} =
               update.("UPDATE relay.fault_injections SET rate_percent = 1 WHERE id = $1")

      assert {:error, %Postgrex.Error{}} =
               update.("DELETE FROM relay.fault_injections WHERE id = $1")

      assert {:error, %Postgrex.Error{}} =
               update.(
                 "UPDATE relay.fault_injections SET expires_at = created_at + interval '2 hours' WHERE id = $1"
               )
    end

    test "OP-44: the release command engages, lists and clears the same records" do
      opts = [
        operator: "ops@example",
        reason: "game day",
        kind: :added_latency,
        delay_ms: 250,
        rate: 10,
        ttl: "30m",
        environment: :test
      ]

      assert {:ok, %{result: :engaged, id: id}} = Command.engage(opts)
      assert {:ok, %{result: :exists, id: ^id}} = Command.engage(opts)
      assert {:ok, %{fault_injections: listed}} = Command.list()
      assert Enum.any?(listed, &(&1.id == id and &1.delay_ms == 250))
      assert Command.engage(Keyword.put(opts, :ttl, "2h")) == {:error, :invalid_ttl}
      assert Command.engage(Keyword.delete(opts, :operator)) == {:error, :operator_required}

      assert {:ok, %{result: :cleared}} =
               Command.clear(id, operator: "ops@example", reason: "done")
    end
  end

  describe "OP-92 decisions on the delivery path" do
    test "OP-92: an expired record is inert and a cleared one never applies" do
      now = DateTime.utc_now()
      expired = record(expires_at: DateTime.add(now, -1, :second))
      cleared = record(status: :cleared)

      refute Evaluation.applies?(expired, point(), now, false)
      refute Evaluation.applies?(cleared, point(), now, false)
      assert FaultInjection.provider_fault(point(), records: [expired, cleared]) == nil
    end

    test "OP-92: a live record acts only in chaos mode; a test record always does" do
      now = DateTime.utc_now()
      live = record(target_environment: :live)

      refute Evaluation.applies?(live, point(environment: :live), now, false)
      assert Evaluation.applies?(live, point(environment: :live), now, true)
      refute Evaluation.applies?(live, point(environment: :test), now, true)
      assert Evaluation.applies?(record([]), point(), now, false)
    end

    test "OP-92: the scope model narrows by tenant, channel and provider" do
      now = DateTime.utc_now()
      tenant = Relay.Id.generate()
      narrow = record(scope_kind: :tenant, scope_tenant_id: tenant, channel: "sms", provider: "x")

      assert Evaluation.applies?(narrow, point(tenant_id: tenant, provider: "x"), now, false)
      refute Evaluation.applies?(narrow, point(provider: "x"), now, false)
      refute Evaluation.applies?(narrow, point(tenant_id: tenant, channel: "email"), now, false)
      refute Evaluation.applies?(narrow, point(tenant_id: tenant, provider: "y"), now, false)
      assert Evaluation.applies?(narrow, %{tenant_id: tenant, environment: :test}, now, false)
    end

    test "OP-92: the rate decides each call and the kinds map to their effects" do
      auth = record(kind: :provider_auth_error, rate_percent: 40)

      assert FaultInjection.provider_fault(point(), records: [auth], draw: fn -> 40 end) ==
               {:fail, :provider_auth_error}

      assert FaultInjection.provider_fault(point(), records: [auth], draw: fn -> 41 end) == nil

      zero = record(rate_percent: 0)
      assert FaultInjection.provider_fault(point(), records: [zero], draw: fn -> 1 end) == nil

      latency = record(kind: :added_latency, delay_ms: 120)
      assert FaultInjection.provider_fault(point(), records: [latency]) == {:delay, 120}

      report = record(kind: :delayed_delivery_report, delay_ms: 60_000, rate_percent: 50)
      assert FaultInjection.provider_fault(point(), records: [report]) == nil
      assert FaultInjection.report_delay(point(), 10, records: [report]) == 60_000
      assert FaultInjection.report_delay(point(), 60, records: [report]) == 0
      assert FaultInjection.report_delay(point(), 10, records: []) == 0

      stalled = record(kind: :iys_pull_stalled)
      scope = Relay.Scope.new!(Relay.Id.generate(), :test)
      assert FaultInjection.iys_pull_stalled?(scope, records: [stalled])
      refute FaultInjection.iys_pull_stalled?(scope, records: [auth])
    end

    test "OP-49: each provider kind answers its failure class in place of the provider" do
      expected = %{
        provider_auth_error: {"auth", nil, nil},
        rate_limited_429: {"transient", "rate_limited", 429},
        concurrency_exhausted: {"transient", "server_error", 503},
        bounce_spike: {"permanent_target", nil, nil},
        template_paused: {"permanent_content", nil, nil}
      }

      for {kind, {class, condition, status}} <- expected do
        outcome = Relay.Channels.fault_outcome(kind)
        assert outcome.state == :failed
        actual = {outcome.failure_class, outcome.condition, outcome.status}
        assert actual == {class, condition, status}
        assert outcome.raw_code == "chaos:#{kind}"
      end
    end

    test "OP-92: with no record in force the lookup reads only the node cache" do
      assert FaultInjection.provider_fault(point()) == nil
      assert FaultInjection.report_delay(point(), 1) == 0
      refute FaultInjection.iys_pull_stalled?(Relay.Scope.new!(Relay.Id.generate(), :test))
    end
  end
end
