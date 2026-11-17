defmodule RelayWeb.Api.AgentsTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.AccessHandler
  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Isolation
  alias RelayTest.TenantFixture

  @agent_scopes ~w(agent:send agent:waitpoint agent:mailbox presence:read)
  @server_scopes ~w(publish read subscribers config kill_switch agents)
  @append "SELECT result FROM relay_fn.mailbox_append($1, $2, 'message', 'inbox.message', NULL, NULL, NULL, NULL, NULL, NULL, $3, NULL)"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{tenant: tenant, scope: scope, token: F.token(scope)}
  end

  defp party, do: "agent-" <> TenantFixture.random()

  defp agent!(ctx, fields \\ %{}) do
    body =
      Map.merge(
        %{
          "name" => "Billing agent",
          "owner_ref" => "work:team-7",
          "access" => %{"party" => party()}
        },
        fields
      )

    F.body(F.request(:post, "/v1/agents", ctx.token, body), 201)
  end

  defp get(ctx, path), do: F.body(F.request(:get, path, ctx.token), 200)

  defp patch(ctx, id, body, headers) do
    path = "/v1/agents/" <> id
    auth = Api.auth(ctx.token, :patch, path)
    headers = [{"content-type", "application/merge-patch+json"}, F.key() | auth] ++ headers

    Api.conn(:patch, path, Jason.encode!(body), headers)
    |> Api.call(RelayWeb.Router)
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp rows(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp mailbox_id(agent) do
    {:ok, id} = Relay.ExternalId.decode(agent["mailbox"]["id"], ["mbx"])
    id
  end

  defp append(scope, agent) do
    params = [Relay.Id.generate(), mailbox_id(agent), TenantFixture.digest()]
    [[result]] = rows(scope, @append, params)
    result
  end

  defp mailbox(scope, agent) do
    sql = """
    SELECT m.state, m.deleted_at,
      (SELECT count(*) FROM relay.mailbox_records r WHERE r.mailbox_id = m.id)
    FROM relay.mailboxes m WHERE m.id = $1
    """

    [row] = rows(scope, sql, [mailbox_id(agent)])
    row
  end

  defp credential(ctx, party, scopes) do
    client = FakeAccess.client!(ctx.scope, scopes)
    access_tenant = ctx.tenant.attrs.access_tenant_id
    FakeAccess.server_token(access_tenant, client, Enum.join(scopes, " "), %{"sub" => party})
  end

  defp event(extra \\ %{}) do
    to = [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}]
    Map.merge(%{"workflow" => "order-shipped", "to" => to, "data" => %{"order" => "A-1"}}, extra)
  end

  defp notification(ctx, accepted) do
    [%{"notification_id" => id}] = accepted["notifications"]
    get(ctx, "/v1/notifications/" <> id)
  end

  defp deliver!(ctx, type, party) do
    data = %{"tenant" => ctx.tenant.attrs.access_tenant_id, "subject" => party}
    claims = FakeAccess.event(type, data)
    assert FakeAccess.deliver(claims).status == 202
    receipts = Enum.map(FakeAccess.drain!(), &FakeAccess.receipt/1)
    Enum.find(receipts, &(&1["webhook_id"] == claims["jti"]))
  end

  describe "C-21 E-28 agent recipient record" do
    test "C-21, E-28, C-68: an agent is created with its Access binding, one mailbox, endpoints and topics",
         ctx do
      endpoint = Isolation.webhook_endpoint!(ctx.scope)
      F.body(F.request(:post, "/v1/topics", ctx.token, %{"key" => "reports"}), 201)
      bound = party()

      created =
        agent!(ctx, %{
          "access" => %{"party" => bound},
          "endpoints" => %{"webhook_endpoint_id" => endpoint, "realtime" => true},
          "topics" => ["reports"]
        })

      assert %{
               "object" => "agent",
               "name" => "Billing agent",
               "owner_ref" => "work:team-7",
               "access" => %{"party" => ^bound},
               "endpoints" => %{
                 "webhook_endpoint_id" => ^endpoint,
                 "a2a_push_endpoint_id" => nil,
                 "realtime" => true
               },
               "mailbox" => %{"id" => "mbx_" <> _, "state" => "active"},
               "topics" => ["reports"],
               "state" => "active",
               "version" => 1
             } = created

      assert "agt_" <> _ = created["id"]
      assert get(ctx, "/v1/agents/" <> created["id"]) == created
      assert [listed] = get(ctx, "/v1/agents")["data"]
      assert listed == created

      {:ok, id} = Relay.ExternalId.decode(created["id"], ["agt"])
      sql = "SELECT count(*) FROM relay.mailboxes WHERE owner_kind = 'agent' AND owner_ref = $1"
      assert rows(ctx.scope, sql, [id]) == [[1]]
      kind = "SELECT kind FROM relay.recipients WHERE id = $1"
      assert rows(ctx.scope, kind, [id]) == [["agent"]]
    end

    test "E-29, C-21: the Access binding is mandatory and an Access Party is bound to one record",
         ctx do
      body = %{"name" => "Unbound", "owner_ref" => "work:team-7"}
      assert code(F.request(:post, "/v1/agents", ctx.token, body), 422) == "validation_failed"

      bound = party()
      agent!(ctx, %{"access" => %{"party" => bound}})
      again = Map.put(body, "access", %{"party" => bound})
      assert code(F.request(:post, "/v1/agents", ctx.token, again), 409) == "resource_conflict"
    end

    test "C-21, E-28: an unknown endpoint or topic is refused with its pointer and nothing is written",
         ctx do
      missing = "whe_01j9zq3k4m5n6p7q8r9s0t1v2w"
      body = %{"name" => "A", "owner_ref" => "o", "access" => %{"party" => party()}}

      refused = Map.put(body, "endpoints", %{"a2a_push_endpoint_id" => missing})
      problem = F.body(F.request(:post, "/v1/agents", ctx.token, refused), 422)
      assert [%{"pointer" => "/endpoints", "code" => "not_found"}] = problem["errors"]

      refused = Map.put(body, "topics", ["nothing"])
      problem = F.body(F.request(:post, "/v1/agents", ctx.token, refused), 422)
      assert [%{"pointer" => "/topics", "code" => "not_found"}] = problem["errors"]

      assert get(ctx, "/v1/agents")["data"] == []
    end

    test "C-21, E-29: an agent is changed under If-Match and its binding and state cannot be patched",
         ctx do
      F.body(F.request(:post, "/v1/topics", ctx.token, %{"key" => "reports"}), 201)
      F.body(F.request(:post, "/v1/topics", ctx.token, %{"key" => "alerts"}), 201)
      created = agent!(ctx, %{"topics" => ["reports"]})
      id = created["id"]

      assert code(patch(ctx, id, %{"name" => "Renamed"}, []), 428) == "precondition_required"
      stale = [{"if-match", ~s("9")}]
      assert code(patch(ctx, id, %{"name" => "Renamed"}, stale), 412) == "precondition_failed"

      current = [{"if-match", ~s("1")}]
      body = %{"name" => "Renamed", "topics" => ["alerts"], "endpoints" => %{"realtime" => true}}
      updated = F.body(patch(ctx, id, body, current), 200)

      assert %{"name" => "Renamed", "topics" => ["alerts"], "version" => 2} = updated
      assert updated["endpoints"]["realtime"] == true
      assert updated["access"] == created["access"]
      assert updated["owner_ref"] == created["owner_ref"]
      assert get(ctx, "/v1/agents/" <> id) == updated

      next = [{"if-match", ~s("2")}]
      rebind = %{"access" => %{"party" => party()}}
      assert code(patch(ctx, id, rebind, next), 422) == "unknown_field"
      assert code(patch(ctx, id, %{"state" => "suspended"}, next), 422) == "unknown_field"
      assert get(ctx, "/v1/agents/" <> id) == updated
    end

    test "C-21: an unknown agent is 404", ctx do
      path = "/v1/agents/agt_01j9zq3k4m5n6p7q8r9s0t1v2w"
      assert code(F.request(:get, path, ctx.token), 404) == "agent_not_found"
      assert code(F.request(:delete, path, ctx.token), 404) == "agent_not_found"
      assert code(F.request(:get, "/v1/agents/sub_nothing", ctx.token), 404) == "agent_not_found"
    end
  end

  describe "AG-5 AG-23 INV-47 soft delete" do
    test "AG-23, INV-47: deleting an agent keeps the record, its mailbox and the records in it",
         ctx do
      bound = party()
      created = agent!(ctx, %{"access" => %{"party" => bound}})
      path = "/v1/agents/" <> created["id"]
      assert append(ctx.scope, created) == "appended"

      deleted = F.body(F.request(:delete, path, ctx.token), 200)
      assert %{"state" => "deleted", "mailbox" => %{"state" => "suspended"}} = deleted
      assert deleted["deleted_at"] != nil
      assert deleted["id"] == created["id"]

      assert ["suspended", nil, 1] = mailbox(ctx.scope, created)
      assert append(ctx.scope, created) == "mailbox_inactive"
      assert get(ctx, path)["state"] == "deleted"
      assert F.body(F.request(:delete, path, ctx.token), 200)["state"] == "deleted"

      current = [{"if-match", ~s("#{deleted["version"]}")}]
      refused = patch(ctx, created["id"], %{"name" => "Back"}, current)
      assert code(refused, 409) == "resource_conflict"

      again = agent!(ctx, %{"access" => %{"party" => bound}})
      assert again["id"] != created["id"]
      assert Enum.map(get(ctx, "/v1/agents")["data"], & &1["state"]) == ["active", "deleted"]
    end
  end

  describe "E-29 AG-5 INV-47 Access binding" do
    test "E-29, AG-5, INV-47: an Access suspension stops delivery to the agent and keeps its mailbox",
         ctx do
      bound = party()
      created = agent!(ctx, %{"access" => %{"party" => bound}})
      path = "/v1/agents/" <> created["id"]
      assert append(ctx.scope, created) == "appended"

      assert %{"state" => "processed"} = deliver!(ctx, "agent.suspended", bound)

      suspended = get(ctx, path)
      assert %{"state" => "suspended", "mailbox" => %{"state" => "suspended"}} = suspended
      assert suspended["suspended_at"] != nil
      assert append(ctx.scope, created) == "mailbox_inactive"
      assert ["suspended", nil, 1] = mailbox(ctx.scope, created)

      assert %{"state" => "processed"} = deliver!(ctx, "agent.suspended", bound)
      assert get(ctx, path)["version"] == suspended["version"]

      assert %{"state" => "processed"} = deliver!(ctx, "agent.reactivated", bound)
      assert %{"state" => "active", "suspended_at" => nil} = get(ctx, path)
      assert append(ctx.scope, created) == "appended"
      assert ["active", nil, 2] = mailbox(ctx.scope, created)
    end

    test "E-29, AG-5, AG-23, INV-47: an Access deletion deletes the record and never its mailbox",
         ctx do
      bound = party()
      created = agent!(ctx, %{"access" => %{"party" => bound}})
      path = "/v1/agents/" <> created["id"]
      assert append(ctx.scope, created) == "appended"

      assert %{"state" => "processed"} = deliver!(ctx, "agent.deleted", bound)

      assert %{"state" => "deleted", "mailbox" => %{"state" => "suspended"}} = get(ctx, path)
      assert ["suspended", nil, 1] = mailbox(ctx.scope, created)
      assert append(ctx.scope, created) == "mailbox_inactive"

      assert %{"state" => "processed"} = deliver!(ctx, "agent.reactivated", bound)
      assert get(ctx, path)["state"] == "deleted"
    end

    test "E-29, AG-5: an agent event reaches only the agent bound to its Access Party in its tenant",
         ctx do
      bound = party()
      created = agent!(ctx, %{"access" => %{"party" => bound}})
      other = agent!(ctx)

      stranger = TenantFixture.tenant!()
      foreign = %{tenant: stranger, scope: stranger.test, token: F.token(stranger.test)}
      same_party = agent!(foreign, %{"access" => %{"party" => bound}})

      assert :ok = AccessHandler.handle_agent_event(ctx.scope, :suspended, bound, "evt-1")
      assert :ok = AccessHandler.handle_agent_event(ctx.scope, :suspended, party(), "evt-2")
      assert :ok = AccessHandler.handle_agent_event(ctx.tenant.live, :suspended, bound, "evt-3")

      assert get(ctx, "/v1/agents/" <> created["id"])["state"] == "suspended"
      assert get(ctx, "/v1/agents/" <> other["id"])["state"] == "active"
      assert get(foreign, "/v1/agents/" <> same_party["id"])["state"] == "active"

      assert %{"state" => "rejected", "reason" => "subject_missing"} =
               deliver!(ctx, "agent.suspended", "")
    end

    test "E-29, AG-5: a suspended or deleted agent's own requests are refused", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      bound = party()
      created = agent!(ctx, %{"access" => %{"party" => bound}})
      agent = credential(ctx, bound, ["agent:send"])

      F.body(F.request(:post, "/v1/events", agent, event()), 202)

      assert %{"state" => "processed"} = deliver!(ctx, "agent.suspended", bound)
      assert code(F.request(:post, "/v1/events", agent, event()), 403) == "auth_agent_inactive"

      assert %{"state" => "processed"} = deliver!(ctx, "agent.reactivated", bound)
      F.body(F.request(:post, "/v1/events", agent, event()), 202)

      F.body(F.request(:delete, "/v1/agents/" <> created["id"], ctx.token), 200)
      assert code(F.request(:post, "/v1/events", agent, event()), 403) == "auth_agent_inactive"
    end
  end

  describe "AG-6 agent scopes" do
    test "AG-6: the agent scopes are four narrow scopes and none covers the others" do
      assert Relay.Access.agent_scopes() == @agent_scopes
      assert Relay.Access.server_scopes() == @server_scopes
      assert Enum.all?(@agent_scopes, &(&1 not in @server_scopes))

      enum = Relay.Api.Contract.documents()["schemas"]["ApiClientScope"]["enum"]
      assert Enum.sort(enum) == Enum.sort(@agent_scopes ++ @server_scopes)

      for operation <- Relay.Api.Contract.operations(), scopes = operation.scopes do
        assert Enum.count(@agent_scopes, &(&1 in scopes)) <= 1, operation.id
      end
    end

    test "AG-6: a client holds agent scopes or server scopes, never both", ctx do
      assert :ok = Relay.Access.assignable_scopes(@agent_scopes)
      assert :ok = Relay.Access.assignable_scopes(@server_scopes)

      for mixed <- [["agent:send", "read"], ["presence:read", "agents"], ["everything"], []] do
        assert {:error, %Relay.Error{code: :validation_failed}} =
                 Relay.Access.assignable_scopes(mixed)
      end

      assert {:error, %Relay.Error{code: :validation_failed}} =
               Relay.Access.assign_api_client(
                 ctx.scope,
                 "app_mixed",
                 ["agent:mailbox", "config"],
                 TenantFixture.actor()
               )

      assert_raise Postgrex.Error, ~r/api_clients_scope_family_check/, fn ->
        FakeAccess.client!(ctx.scope, ["agent:send", "publish"])
      end
    end

    test "AG-6, E-29: an agent's credential is granted only the scopes it holds", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      bound = party()
      agent!(ctx, %{"access" => %{"party" => bound}})

      mailbox_only = credential(ctx, bound, ["agent:mailbox", "presence:read"])
      refused = F.body(F.request(:post, "/v1/events", mailbox_only, event()), 403)
      assert refused["code"] == "auth_insufficient_scope"
      refute Map.has_key?(refused, "granted_scopes")

      sender = credential(ctx, bound, ["agent:send"])
      F.body(F.request(:post, "/v1/events", sender, event()), 202)

      for path <- ["/v1/agents", "/v1/notifications", "/v1/topics", "/v1/subscribers"] do
        assert code(F.request(:get, path, sender), 403) == "auth_insufficient_scope"
      end
    end

    test "AG-6, E-29: agent scopes without a bound agent record grant nothing", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      unbound = credential(ctx, party(), ["agent:send"])

      assert code(F.request(:post, "/v1/events", unbound, event()), 403) == "auth_agent_inactive"
    end
  end

  describe "E-55 E-56 agent senders" do
    test "E-56, PC-57: an agent's send is labelled agent-originated whatever the request says",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      bound = party()
      agent!(ctx, %{"access" => %{"party" => bound}})
      agent = credential(ctx, bound, ["agent:send"])

      plain = F.body(F.request(:post, "/v1/events", agent, event()), 202)
      assert notification(ctx, plain)["sender_type"] == "agent"

      claimed = event(%{"actor" => %{"type" => "human", "id" => "someone-else"}})
      disguised = F.body(F.request(:post, "/v1/events", agent, claimed), 202)
      assert notification(ctx, disguised)["sender_type"] == "agent"
    end

    test "E-55, E-56: an agent sender has no special status in the lattice", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      bound = party()
      agent!(ctx, %{"access" => %{"party" => bound}})
      agent = credential(ctx, bound, ["agent:send"])

      external_id = "user-" <> TenantFixture.random()
      subscriber = %{"external_id" => external_id, "email" => "ayse@example.com"}
      F.body(F.request(:post, "/v1/subscribers", ctx.token, subscriber), 201)
      off = %{"level" => "channel", "channel" => "email", "value" => "opt_out"}
      path = "/v1/subscribers/#{external_id}/preferences"
      F.body(F.request(:patch, path, ctx.token, %{"preferences" => [off]}), 200)

      decisions =
        for token <- [ctx.token, agent] do
          body = event(%{"to" => [external_id]})
          accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
          [%{"notification_id" => id}] = accepted["notifications"]
          deliveries = get(ctx, "/v1/notifications/#{id}/deliveries")["data"]
          Enum.map(deliveries, &{&1["status"], &1["rule_id"]})
        end

      assert [system, from_agent] = decisions
      assert system == from_agent
      assert [{"skipped", "preference.channel"}] = from_agent
    end

    test "E-55: nothing of an agent's memory, plan or reasoning is accepted", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      bound = party()
      agent!(ctx, %{"access" => %{"party" => bound}})
      agent = credential(ctx, bound, ["agent:send"])

      for field <- ["memory", "plan", "reasoning"] do
        body = event(%{field => %{"notes" => "private"}})
        assert code(F.request(:post, "/v1/events", agent, body), 422) == "unknown_field"

        record = %{"name" => "A", "owner_ref" => "o", "access" => %{"party" => party()}}
        refused = F.request(:post, "/v1/agents", ctx.token, Map.put(record, field, "x"))
        assert code(refused, 422) == "unknown_field"
      end
    end
  end
end
