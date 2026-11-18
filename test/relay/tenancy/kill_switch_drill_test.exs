defmodule Relay.Tenancy.KillSwitchDrillTest do
  use Relay.SqlCase, async: false

  alias Relay.Platform.Signal.Hub
  alias Relay.Repo
  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Snapshot
  alias RelayTest.TenantFixture

  @operator %{kind: :installation_operator, ref: "drill@example"}
  @nodes 3
  @pending 200
  @engage "SELECT * FROM relay_fn.kill_switch_engage($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21)"
  @record "SELECT scope_kind, scope_ref, channel, target_kind, target_ref, message_class, state,
    canary_percent, reason, origin, created_by_ref, status FROM relay.kill_switches WHERE id = $1"
  @paused "SELECT count(*) FROM relay.deliveries WHERE pause_kill_switch_id = $1"
  @audit_fields ~w(action actor_kind actor_ref on_behalf_of_ref target_type reason record_digest)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp wait(fun, until) do
    cond do
      fun.() -> now_ms()
      now_ms() > until -> flunk("condition not reached in time")
      true -> Process.sleep(10) && wait(fun, until)
    end
  end

  defp node! do
    name = make_ref()
    start_supervised!({Cache, name: name, refresh_ms: 600_000}, id: name)
    on_exit(fn -> Cache.forget(name) end)
    wait(fn -> Cache.current(name) != :unknown end, now_ms() + 5_000)
    name
  end

  defp holds?(name, id) do
    case Cache.current(name) do
      %Snapshot{index: index} ->
        index |> Map.values() |> List.flatten() |> Enum.any?(&(&1.id == id))

      :unknown -> false
    end
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 3_600, :second)

  defp internal(external) do
    {:ok, id} = Relay.ExternalId.decode(external, ["ksw"])
    id
  end

  defp installation, do: Relay.Scope.new!(KillSwitch.Store.installation_tenant_id(), :live)

  defp in_scope(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp audits(scope, target) do
    now = DateTime.utc_now()
    reader = [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
    window = [DateTime.add(now, -3_600), DateTime.add(now, 3_600), "killswitch.engaged"]
    query = fn _status -> Repo.call!("relay_fn.audit_query", window ++ [nil, 1_000 | reader]) end
    {:ok, rows} = Repo.in_scope(scope, query)

    for row <- rows, row["target_id"] == Relay.Id.to_string(target) do
      Enum.map(@audit_fields, &row[&1])
    end
  end

  defp sweep_all(scope, id) do
    case KillSwitch.sweep(scope, id) do
      {_paused, true} -> sweep_all(scope, id)
      {_paused, false} -> :ok
    end
  end

  describe "TN-39 TN-45 OP-47 kill switch drills" do
    test "TN-39: a platform kill switch reaches three nodes within two seconds" do
      nodes = for _ <- 1..@nodes, do: node!()
      wait(fn -> Hub.topics(Hub)[Cache.topic()] == :up end, now_ms() + 5_000)

      started = now_ms()

      {:ok, %{result: :engaged, id: external}} =
        KillSwitch.engage(
          %{scope_kind: :platform, reason: "drill", expires_at: later(), channel: "voice"},
          @operator
        )

      id = internal(external)
      reached = for name <- nodes, do: wait(fn -> holds?(name, id) end, started + 2_000) - started
      IO.puts("kill switch propagation ms: #{inspect(reached)}")
      assert Enum.max(reached) <= 2_000
    end

    test "TN-45: the emergency database procedure writes the operator path's record and audit" do
      node = node!()
      wait(fn -> Hub.topics(Hub)[Cache.topic()] == :up end, now_ms() + 5_000)
      scope = installation()
      expires_at = later()

      {:ok, %{result: :engaged, id: external}} =
        KillSwitch.engage(
          %{
            scope_kind: :platform,
            reason: "emergency drill",
            expires_at: expires_at,
            channel: "sms"
          },
          @operator
        )

      api = internal(external)
      emergency = Relay.Id.generate()

      digest =
        Relay.Audit.record_digest(%{
          tenant_id: scope.tenant_id,
          environment: "live",
          action: "killswitch.engaged",
          actor_kind: "installation_operator",
          actor_ref: "drill@example",
          on_behalf_of_ref: "drill@example",
          access_record_ref: nil,
          target_type: "kill_switch",
          target_id: Relay.Id.to_string(emergency),
          reason: "emergency drill"
        })

      params =
        [emergency, "platform", nil, "sms", "all", nil, nil, nil, "off", nil, nil] ++
          ["emergency drill", nil, expires_at, nil, "operator", digest] ++
          ["installation_operator", "drill@example", "drill@example", nil]

      started = now_ms()
      [["engaged", ^emergency, generation]] = in_scope(scope, @engage, params)
      :ok = Relay.Platform.publish_signal(Cache.topic(), generation)
      reached = wait(fn -> holds?(node, emergency) end, started + 2_000) - started
      assert reached <= 2_000

      assert in_scope(scope, @record, [emergency]) == in_scope(scope, @record, [api])

      [[action, kind, ref, behalf, type, reason, stored]] =
        audits(scope, emergency)

      [[^action, ^kind, ^ref, ^behalf, ^type, ^reason, _digest]] =
        audits(scope, api)

      assert {action, kind, ref, type} ==
               {"killswitch.engaged", "installation_operator", "drill@example", "kill_switch"}

      assert stored == digest
    end

    test "OP-47: a mass mis-send stops within 60 seconds through the kill switch and its holds" do
      tenant = TenantFixture.tenant!()
      scope = tenant.live
      keys = TenantFixture.keys!(scope)
      recipient = TenantFixture.recipient!(scope, keys)
      notifications = for _ <- 1..@pending, do: TenantFixture.notification(recipient)

      {:ok, _} =
        Relay.Ingest.accept(
          scope,
          TenantFixture.accept_request(notifications, data_key: keys.data)
        )

      started = now_ms()

      {:ok, %{result: :engaged, id: external}} =
        KillSwitch.engage(
          %{scope_kind: :tenant, scope: scope, reason: "mis-send", expires_at: later()},
          @operator
        )

      id = internal(external)
      :ok = sweep_all(scope, id)
      elapsed = now_ms() - started

      [[paused]] = in_scope(scope, @paused, [id])

      IO.puts("mass mis-send stop ms: #{elapsed} for #{paused} deliveries")
      assert paused == @pending
      assert elapsed < 60_000

      [delivery | _] = for n <- notifications, d <- n.deliveries, do: d.id
      snapshot = KillSwitch.current_snapshot()
      assert KillSwitch.first_step(scope, delivery, snapshot: snapshot) == {:done, :paused}
    end
  end
end
