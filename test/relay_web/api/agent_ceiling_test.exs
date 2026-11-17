defmodule RelayWeb.Api.AgentCeilingTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.Ceiling
  alias Relay.Api.AgentCeilings
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    key = "agent-" <> TenantFixture.random()
    F.workflow!(scope, token, key, category: "orders", message_class: "transactional")
    party = "agent-" <> TenantFixture.random()
    access = %{"party" => party}
    body = %{"name" => "Billing agent", "owner_ref" => "work:team-7", "access" => access}
    %{"id" => agent} = F.body(F.request(:post, "/v1/agents", token, body), 201)
    {:ok, client} = Relay.ExternalId.decode(agent, ["agt"])
    credential = FakeAccess.client!(scope, ["agent:send"])
    access_tenant = tenant.attrs.access_tenant_id
    sender = FakeAccess.server_token(access_tenant, credential, "agent:send", %{"sub" => party})
    path = "/v1/agents/" <> agent
    %{scope: scope, token: token, sender: sender, workflow: key, client: client, agent: path}
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

  defp with_counter(fun) do
    previous = Application.get_env(:relay, Relay.Policy.Live)
    options = Keyword.put(previous || [], :agent_ceiling, counter: counter())
    Application.put_env(:relay, Relay.Policy.Live, options)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:relay, Relay.Policy.Live, previous),
        else: Application.delete_env(:relay, Relay.Policy.Live)
    end
  end

  defp send!(ctx) do
    to = %{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}
    body = %{"workflow" => ctx.workflow, "to" => [to], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.sender, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery | _] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    {notification, Relay.Policy.Live.job(ctx.scope, delivery_id)}
  end

  defp hold!(ctx) do
    digest = TenantFixture.digest()
    change = %{key: "agents.ceiling.per_hour", value: 1, expected_version: nil}
    change = Map.put(change, :record_digest, digest)
    assert {:ok, _} = Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())
    assert {_first, {:send, _info}} = send!(ctx)
    assert {held, :done} = send!(ctx)
    [[event_id]] = sql!(ctx.scope, "SELECT id FROM relay.agent_ceiling_events", [])
    {held, Relay.ExternalId.encode("oev", event_id)}
  end

  defp decision(event, decision),
    do: %{"decision" => decision, "ceiling_event_id" => event, "decision_ref" => "work:1"}

  defp post(ctx, path, body), do: F.request(:post, ctx.agent <> path, ctx.token, body)

  defp operator do
    {:ok, actor} = Relay.Actor.new(:operator, "acc_op_1", "acc_op_1", "step-up:1")
    actor
  end

  describe "AG-49 listing the held notifications" do
    test "AG-49, INV-3: the owner sees the held notifications of an agent", ctx do
      with_counter(fn ->
        {held, event} = hold!(ctx)

        page = F.body(F.request(:get, ctx.agent <> "/ceiling_holds", ctx.token), 200)
        assert [%{"object" => "ceiling_hold", "notification_id" => ^held} = hold] = page["data"]
        assert hold["state"] == "held"
        assert hold["rule_id"] == "agent_ceiling.exceeded"
        assert hold["ceiling_event_id"] == event
        assert hold["decision_id"] == nil

        path = ctx.agent <> "/ceiling_holds?state=released"
        assert F.body(F.request(:get, path, ctx.token), 200)["data"] == []
        assert [%{"held_count" => 1}] = OutboxEvents.data(ctx.scope, "agent.ceiling_exceeded")
      end)
    end

    test "AG-49: an unknown agent is not found and an unknown state is refused", ctx do
      unknown = "/v1/agents/" <> Relay.ExternalId.encode("agt", Relay.Id.generate())

      assert %{"code" => "agent_not_found"} =
               F.body(F.request(:get, unknown <> "/ceiling_holds", ctx.token), 404)

      path = ctx.agent <> "/ceiling_holds?state=sent"
      assert %{"code" => "validation_failed"} = F.body(F.request(:get, path, ctx.token), 422)
    end
  end

  describe "AG-49 TN-21 deciding" do
    test "TN-21: an API client cannot release held notifications", ctx do
      with_counter(fn ->
        {_held, event} = hold!(ctx)

        refused = post(ctx, "/ceiling_decisions", decision(event, "send_all"))
        assert %{"code" => "auth_operator_session_required"} = F.body(refused, 403)

        page = F.body(F.request(:get, ctx.agent <> "/ceiling_holds?state=held", ctx.token), 200)
        assert length(page["data"]) == 1
      end)
    end

    test "TN-21, TN-47: a tenant administrator with step-up releases them", ctx do
      with_counter(fn ->
        {held, event} = hold!(ctx)
        body = decision(event, "send_all")

        assert {:ok, {201, view}} =
                 AgentCeilings.decide_as_operator(ctx.scope, ctx.client, body, operator())

        assert %{"decision" => "send_all", "applied_count" => 1, "agent_state" => "active"} = view
        {:ok, decision_id} = Relay.ExternalId.decode(view["id"], ["acd"])
        assert {:ok, %{resumed: 1}} = Ceiling.apply_decision(ctx.scope, decision_id)

        path = ctx.agent <> "/ceiling_holds?state=released"

        assert [%{"notification_id" => ^held, "decision_id" => id}] =
                 F.body(F.request(:get, path, ctx.token), 200)["data"]

        assert id == view["id"]
      end)
    end

    test "AG-49: cancel is recorded once and a different decision conflicts", ctx do
      with_counter(fn ->
        {_held, event} = hold!(ctx)

        first = F.body(post(ctx, "/ceiling_decisions", decision(event, "cancel")), 201)
        assert %{"object" => "ceiling_decision", "decision" => "cancel"} = first
        assert first["applied_count"] == 1
        assert first["ceiling_event_id"] == event

        again = F.body(post(ctx, "/ceiling_decisions", decision(event, "cancel")), 201)
        assert again["id"] == first["id"]

        conflict = post(ctx, "/ceiling_decisions", decision(event, "stop"))
        assert %{"code" => "ceiling_decision_conflict"} = F.body(conflict, 409)

        other = Relay.ExternalId.encode("oev", Relay.Id.generate())
        missing = post(ctx, "/ceiling_decisions", decision(other, "cancel"))
        assert %{"code" => "ceiling_event_not_found"} = F.body(missing, 422)
      end)
    end

    test "AG-49: stop stops the agent and resume lifts the stop", ctx do
      with_counter(fn ->
        {_held, event} = hold!(ctx)

        stopped = F.body(post(ctx, "/ceiling_decisions", decision(event, "stop")), 201)
        assert stopped["agent_state"] == "stopped"

        resumed = F.body(post(ctx, "/resume", %{"decision_ref" => "work:2"}), 200)
        assert %{"object" => "agent_state", "state" => "active"} = resumed
        assert resumed["decision_ref"] == "work:2"

        unchanged = F.body(post(ctx, "/resume", %{"decision_ref" => "work:3"}), 200)
        assert unchanged["decision_ref"] == "work:2"
      end)
    end
  end
end
