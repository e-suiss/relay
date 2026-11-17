defmodule Relay.Agents.CeilingTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.Ceiling
  alias Relay.Agents.Ceiling.Decision
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @scopes ["publish", "read", "subscribers", "config", "kill_switch"]
  @exceeded "agent_ceiling.exceeded"
  @unreadable "agent_ceiling.counter_unreadable"
  @delivery "SELECT paused_at, pause_rule_id::text, failure_kind FROM relay.deliveries WHERE id = $1"

  setup do
    tenant = TenantFixture.tenant!()
    Map.put(world(tenant.live), :tenant, tenant)
  end

  defp world(scope) do
    access_client = FakeAccess.client!(scope, @scopes)
    clients = "SELECT id FROM relay.api_clients WHERE access_client_id = $1"
    [[client]] = sql!(scope, clients, [access_client])
    cli = Relay.ExternalId.encode("cli", client)
    token = RelayTest.Api.token(scope, @scopes, api_client_id: cli)
    key = "agent-" <> TenantFixture.random()
    F.workflow!(scope, token, key, category: "orders", message_class: "transactional")
    %{scope: scope, token: token, workflow: key}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp counter do
    fn _scope, key, _window_ms, op, by ->
      count = Process.get({:count, key}, 0) + if(op == :incr, do: by, else: 0)
      Process.put({:count, key}, count)
      {:ok, count}
    end
  end

  defp down do
    fn _scope, _key, _window_ms, _op, _by ->
      {:error, Relay.Error.new(:valkey_unavailable, "down")}
    end
  end

  defp with_counter(counter, fun) do
    previous = Application.get_env(:relay, Relay.Policy.Live)
    options = Keyword.put(previous || [], :agent_ceiling, counter: counter)
    Application.put_env(:relay, Relay.Policy.Live, options)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:relay, Relay.Policy.Live, previous),
        else: Application.delete_env(:relay, Relay.Policy.Live)
    end
  end

  defp lower!(scope, key, value) do
    digest = TenantFixture.digest()
    change = %{key: key, value: value, expected_version: nil, record_digest: digest}
    assert {:ok, _} = Relay.Tenancy.put_setting(scope, change, TenantFixture.actor())
  end

  defp send!(ctx, sender, extra \\ %{}) do
    to = %{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}
    body = %{"workflow" => ctx.workflow, "to" => [to], "data" => %{"order" => "A-1"}}
    body = if sender, do: Map.put(body, "actor", %{"type" => sender}), else: body
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, Map.merge(body, extra)), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery | _] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, notification_id} = Relay.ExternalId.decode(notification, ["ntf"])
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    %{notification_id: notification_id, delivery_id: delivery_id}
  end

  defp job(ctx, sent), do: Relay.Policy.Live.job(ctx.scope, sent.delivery_id)

  defp agent(scope) do
    sql = "SELECT api_client_id FROM relay.events WHERE sender_type = 'agent' LIMIT 1"
    [[id]] = sql!(scope, sql, [])
    id
  end

  defp delivery(scope, sent) do
    [row] = sql!(scope, @delivery, [sent.delivery_id])
    row
  end

  defp holds(scope, state \\ nil) do
    {:ok, rows} = Ceiling.list_holds(scope, agent(scope), state, nil, 50)
    rows
  end

  defp counted(scope, window),
    do: Process.get({:count, "agent_ceiling:#{window}:" <> Relay.Id.to_string(agent(scope))}, 0)

  defp operator(step_up) do
    {:ok, actor} = Relay.Actor.new(:operator, "acc_op_1", "acc_op_1", step_up)
    actor
  end

  defp decide(scope, decision, event_id, actor) do
    attrs = %{
      agent_ref: agent(scope),
      ceiling_event_id: event_id,
      decision: decision,
      decision_ref: "work:decision:1",
      note: nil
    }

    {:ok, answer} =
      Ceiling.in_scope(scope, fn _status ->
        Ceiling.decide_here(scope, attrs, TenantFixture.digest(), actor)
      end)

    answer
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    Enum.filter(rows, &(&1["action"] == action))
  end

  defp hold_two(ctx) do
    lower!(ctx.scope, "agents.ceiling.per_hour", 1)
    first = send!(ctx, "agent")
    assert {:send, _info} = job(ctx, first)
    second = send!(ctx, "agent")
    assert :done = job(ctx, second)
    third = send!(ctx, "agent")
    assert :done = job(ctx, third)
    {second, third}
  end

  describe "AG-48 AG-70 the ceiling as a decision" do
    test "AG-70: the ceiling is 100 an hour and 1000 a day and a tenant may only lower it" do
      assert Decision.limits(nil, nil) == %{per_hour: 100, per_day: 1000}
      assert Decision.limits(10, 2000) == %{per_hour: 10, per_day: 1000}
      assert Decision.limits(500, 50) == %{per_hour: 100, per_day: 50}
      assert Decision.limits(0, "7") == %{per_hour: 100, per_day: 1000}
    end

    test "AG-48, AG-50: a usage at a limit holds and an unreadable usage holds" do
      limits = Decision.limits(nil, nil)

      assert Decision.decide(%{hour: 99, day: 999}, limits) == :pass
      assert Decision.decide(%{hour: 100, day: 100}, limits) == {:hold, @exceeded}
      assert Decision.decide(%{hour: 1, day: 1000}, limits) == {:hold, @exceeded}
      assert Decision.decide(:unreadable, limits) == {:hold, @unreadable}
    end

    test "AG-48, C-24: only the sender type agent is subject to the ceiling" do
      assert Decision.subject?("agent")
      refute Decision.subject?("human")
      refute Decision.subject?("system")
      refute Decision.subject?(nil)
    end

    test "AG-70: a tenant cannot raise the ceiling", ctx do
      change = %{
        key: "agents.ceiling.per_hour",
        value: 101,
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               Relay.Tenancy.put_setting(
                 ctx.scope,
                 %{change | key: "agents.ceiling.per_day", value: 1001},
                 TenantFixture.actor()
               )
    end
  end

  describe "AG-48 INV-34 who the ceiling applies to" do
    test "INV-34: notifications of human and system senders never reach the ceiling", ctx do
      with_counter(down(), fn ->
        assert {:send, _info} = job(ctx, send!(ctx, nil))
        assert {:send, _info} = job(ctx, send!(ctx, "human"))
      end)

      assert sql!(ctx.scope, "SELECT count(*) FROM relay.agent_ceiling_holds", []) == [[0]]
    end

    test "AG-48: an agent's notification below the ceiling passes and is counted once", ctx do
      with_counter(counter(), fn ->
        sent = send!(ctx, "agent")

        assert {:send, _info} = job(ctx, sent)
        assert {:send, _info} = job(ctx, sent)
        assert counted(ctx.scope, "h") == 1
        assert counted(ctx.scope, "d") == 1
        assert holds(ctx.scope) == []
        assert [nil, nil, nil] = delivery(ctx.scope, sent)
      end)
    end
  end

  describe "AG-49 INV-3 exceeding the ceiling" do
    test "INV-3, AG-49: a notification over the ceiling is held, not sent and not deleted", ctx do
      with_counter(counter(), fn ->
        {second, third} = hold_two(ctx)

        assert [%DateTime{}, @exceeded, nil] = delivery(ctx.scope, second)
        assert [%DateTime{}, @exceeded, nil] = delivery(ctx.scope, third)
        assert :done = job(ctx, second)
        assert [%DateTime{}, @exceeded, nil] = delivery(ctx.scope, second)
        assert counted(ctx.scope, "h") == 1

        held = holds(ctx.scope, "held")
        ids = Enum.sort(Enum.map(held, & &1["notification_id"]))
        assert ids == Enum.sort([second.notification_id, third.notification_id])
        assert Enum.all?(held, &(&1["rule_id"] == @exceeded and &1["state"] == "held"))
      end)
    end

    test "AG-49: the owner is told once with agent.ceiling_exceeded", ctx do
      with_counter(counter(), fn ->
        {_second, _third} = hold_two(ctx)

        assert [event] = OutboxEvents.data(ctx.scope, "agent.ceiling_exceeded")
        assert event["agent_id"] == Relay.ExternalId.encode("agt", agent(ctx.scope))
        assert event["held_count"] == 1

        sql = "SELECT held_count, state, rule_id FROM relay.agent_ceiling_events"
        assert [[2, "open", @exceeded]] = sql!(ctx.scope, sql, [])
      end)
    end

    test "AG-49: the paused expiry sweep leaves a held notification alone", ctx do
      with_counter(counter(), fn ->
        lower!(ctx.scope, "agents.ceiling.per_hour", 1)
        assert {:send, _info} = job(ctx, send!(ctx, "agent"))
        expires_at = DateTime.add(DateTime.utc_now(), 2, :second)
        held = send!(ctx, "agent", %{"expires_at" => DateTime.to_iso8601(expires_at)})
        assert :done = job(ctx, held)
        Process.sleep(2_200)

        assert [[0]] = sql!(ctx.scope, "SELECT relay_fn.paused_deliveries_expire(100)", [])
        assert [%DateTime{}, @exceeded, nil] = delivery(ctx.scope, held)
      end)
    end
  end

  describe "AG-50 INV-34 an unreadable counter" do
    test "INV-34, AG-50: an unreadable counter holds agent notifications only", ctx do
      with_counter(down(), fn ->
        agent = send!(ctx, "agent")

        assert :done = job(ctx, agent)
        assert [%DateTime{}, @unreadable, nil] = delivery(ctx.scope, agent)
        assert [%{"rule_id" => @unreadable, "state" => "held"}] = holds(ctx.scope)
        assert [event] = OutboxEvents.data(ctx.scope, "agent.ceiling_exceeded")
        assert event["held_count"] == 1

        system = send!(ctx, "system")
        assert {:send, _info} = job(ctx, system)
        assert [nil, nil, nil] = delivery(ctx.scope, system)
      end)
    end
  end

  describe "AG-49 TN-21 TN-47 the owner's decision" do
    test "TN-21: releasing held notifications needs a step-up", ctx do
      with_counter(counter(), fn ->
        {second, _third} = hold_two(ctx)
        [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])

        assert {:step_up_required, nil} = decide(ctx.scope, "send_all", event_id, operator(nil))
        assert [%DateTime{}, @exceeded, nil] = delivery(ctx.scope, second)
        assert length(holds(ctx.scope, "held")) == 2
        assert audit(ctx.scope, "agent.ceiling_decided") == []
      end)
    end

    test "AG-49, TN-47: send_all releases every held notification and is audited", ctx do
      with_counter(counter(), fn ->
        {second, third} = hold_two(ctx)
        [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])
        actor = operator("step-up:1")

        assert {:decided, decision} = decide(ctx.scope, "send_all", event_id, actor)
        assert decision["applied_count"] == 2
        assert {:exists, again} = decide(ctx.scope, "send_all", event_id, actor)
        assert again["id"] == decision["id"]
        assert {:conflict, _first} = decide(ctx.scope, "cancel", event_id, actor)
        assert [_record] = audit(ctx.scope, "agent.ceiling_decided")

        assert {:ok, %{resumed: 2, cancelled: 0, expired: 0}} =
                 Ceiling.apply_decision(ctx.scope, decision["id"])

        assert {:ok, %{resumed: 0}} = Ceiling.apply_decision(ctx.scope, decision["id"])
        assert [nil, nil, nil] = delivery(ctx.scope, second)
        assert {:send, _info} = job(ctx, second)
        assert {:send, _info} = job(ctx, third)
        assert length(holds(ctx.scope, "released")) == 2
        assert holds(ctx.scope, "held") == []
      end)
    end

    test "AG-49: a held notification past its expires_at is expired on release", ctx do
      with_counter(counter(), fn ->
        ctx = world(ctx.tenant.test)
        lower!(ctx.scope, "agents.ceiling.per_hour", 1)
        assert {:send, _info} = job(ctx, send!(ctx, "agent"))
        expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
        held = send!(ctx, "agent", %{"expires_at" => DateTime.to_iso8601(expires_at)})
        assert :done = job(ctx, held)
        [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])
        digest = TenantFixture.digest()
        hour = 3_600_000

        assert {:ok, _clock} =
                 Relay.Platform.advance_virtual_clock(ctx.scope, hour, digest, operator(nil))

        actor = operator("step-up:1")
        assert {:decided, decision} = decide(ctx.scope, "send_all", event_id, actor)

        assert {:ok, %{resumed: 0, expired: 1}} =
                 Ceiling.apply_decision(ctx.scope, decision["id"])

        assert [_paused, _rule, "expired"] = delivery(ctx.scope, held)
        assert [%{"state" => "expired"}] = holds(ctx.scope, "expired")
      end)
    end

    test "AG-49: cancel cancels the held notifications and deletes nothing", ctx do
      with_counter(counter(), fn ->
        {second, _third} = hold_two(ctx)
        [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])

        assert {:decided, decision} = decide(ctx.scope, "cancel", event_id, TenantFixture.actor())

        assert {:ok, %{resumed: 0, cancelled: 2}} =
                 Ceiling.apply_decision(ctx.scope, decision["id"])

        assert [_paused, _rule, "cancelled"] = delivery(ctx.scope, second)
        assert length(holds(ctx.scope, "cancelled")) == 2
      end)
    end

    test "AG-49: stop cancels, skips the agent's new notifications and resume lifts it", ctx do
      with_counter(counter(), fn ->
        {_second, _third} = hold_two(ctx)
        [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])
        actor = TenantFixture.actor()
        client = agent(ctx.scope)

        assert {:decided, decision} = decide(ctx.scope, "stop", event_id, actor)
        assert {:ok, %{cancelled: 2}} = Ceiling.apply_decision(ctx.scope, decision["id"])

        stopped = send!(ctx, "agent")
        assert :done = job(ctx, stopped)
        sql = "SELECT decision, decision_rule_id FROM relay.deliveries WHERE id = $1"
        assert [["skip", "agent_ceiling.stopped"]] = sql!(ctx.scope, sql, [stopped.delivery_id])
        assert {:send, _info} = job(ctx, send!(ctx, "system"))

        resume = fn _status ->
          Ceiling.resume_here(client, "work:decision:2", TenantFixture.digest(), actor)
        end

        assert {:ok, {:resumed, %{state: "active"}}} = Ceiling.in_scope(ctx.scope, resume)
        assert {:ok, {:unchanged, %{state: "active"}}} = Ceiling.in_scope(ctx.scope, resume)
        assert [_record] = audit(ctx.scope, "agent.resumed")
      end)
    end
  end
end
