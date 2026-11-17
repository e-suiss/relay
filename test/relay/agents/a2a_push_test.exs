defmodule Relay.Agents.A2aPushTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.A2a
  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Live.A2aPush
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @url "https://agent.example.com/a2a/push"
  @append "SELECT result, epoch, seq FROM relay_fn.mailbox_append($1, $2, 'message', 'inbox.message', NULL, NULL, NULL, NULL, NULL, NULL, $3, NULL)"

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{tenant: tenant, scope: scope, token: F.token(scope)}
  end

  defp post(ctx, path, body), do: F.body(F.request(:post, path, ctx.token, body), 201)

  defp endpoint!(ctx) do
    body = %{
      "use" => "relay_events",
      "destination" => %{"kind" => "https", "url" => @url},
      "event_types" => ["notification.delivered"]
    }

    created = post(ctx, "/v1/webhook_endpoints", body)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp agent!(ctx, endpoints) do
    body = %{
      "name" => "Research agent",
      "owner_ref" => "work:team-7",
      "access" => %{"party" => "agent-" <> TenantFixture.random()},
      "endpoints" => endpoints
    }

    agent = post(ctx, "/v1/agents", body)
    {:ok, mailbox} = Relay.ExternalId.decode(agent["mailbox"]["id"], ["mbx"])
    Map.put(agent, :mailbox, mailbox)
  end

  defp read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  defp append!(ctx, mailbox) do
    id = Relay.Id.generate()
    digest = :crypto.strong_rand_bytes(32)
    rows = read(ctx, fn -> Repo.scoped_query!(@append, [id, mailbox, digest]).rows end)
    [["appended", epoch, seq]] = rows
    %{id: id, epoch: epoch, seq: seq}
  end

  defp hint(mailbox, record) do
    %{
      mailbox_id: Relay.Id.to_string(mailbox),
      record_id: Relay.Id.to_string(record.id),
      epoch: record.epoch,
      seq: record.seq,
      kind: "message",
      traceparent: nil
    }
  end

  defp push!(ctx, mailbox, record), do: read(ctx, fn -> A2aPush.jobs(hint(mailbox, record)) end)

  defp message(ctx, endpoint, record),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, record.id) end)

  defp row(overrides) do
    Map.merge(
      %{
        "mailbox_id" => Relay.Id.generate(),
        "record_id" => Relay.Id.generate(),
        "epoch" => 1,
        "seq" => 7,
        "kind" => "waitpoint_event",
        "event_type" => "waitpoint.created",
        "waitpoint_id" => Relay.Id.generate(),
        "waitpoint_state" => "open",
        "waitpoint_kind" => "question",
        "waitpoint_profile" => nil,
        "created_at" => ~U[2026-11-17 10:00:00.000000Z]
      },
      overrides
    )
  end

  describe "AG-42 E-51 L-28 A2A push is sent by the delivery engine" do
    test "AG-42: the wake hint of an agent's record becomes one signed message for its A2A push endpoint",
         ctx do
      endpoint = endpoint!(ctx)
      agent = agent!(ctx, %{"a2a_push_endpoint_id" => endpoint["id"]})
      record = append!(ctx, agent.mailbox)

      assert push!(ctx, agent.mailbox, record) == []
      assert %{"state" => "pending"} = message = message(ctx, endpoint, record)

      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, message["id"], [])
      assert_received {:webhook_delivery, config, prepared, _opts}

      assert config.url == @url
      assert prepared.type == "a2a.push_notification"
      assert prepared.content_type == "application/json"

      headers = Map.new(prepared.headers)
      assert headers["a2a-version"] == Relay.Agents.protocol_version("a2a")
      assert headers["webhook-id"] == Relay.ExternalId.encode("oev", record.id)
      assert is_binary(headers["webhook-signature"])
      assert is_binary(headers["webhook-timestamp"])

      assert %{"statusUpdate" => update} = body = Jason.decode!(prepared.body)
      assert Map.keys(body) == ["statusUpdate"]
      assert {:ok, %{seq: seq}} = A2a.notification(body)
      assert seq == record.seq
      assert update["contextId"] == agent["mailbox"]["id"]
      assert update["status"]["state"] == "TASK_STATE_UNSPECIFIED"

      assert update["metadata"]["relay"] == %{
               "mailbox_id" => agent["mailbox"]["id"],
               "record_id" => Relay.ExternalId.encode("mbr", record.id),
               "epoch" => record.epoch,
               "seq" => record.seq,
               "kind" => "message",
               "event_type" => "inbox.message",
               "rule" => "hint"
             }
    end

    test "L-28, INV-35: a hint dispatched again creates no second push and a failed push is retried by the engine",
         ctx do
      endpoint = endpoint!(ctx)
      agent = agent!(ctx, %{"a2a_push_endpoint_id" => endpoint["id"]})
      record = append!(ctx, agent.mailbox)

      assert push!(ctx, agent.mailbox, record) == []
      first = message(ctx, endpoint, record)
      assert push!(ctx, agent.mailbox, record) == []
      assert message(ctx, endpoint, record)["id"] == first["id"]

      Fake.answers([Fake.http(503)])
      assert {:ok, {:attempted, state}} = Webhooks.attempt(ctx.scope, first["id"], [])
      refute state == :delivered
      refute message(ctx, endpoint, record)["state"] == "delivered"
    end

    test "AG-21: an agent without an A2A push endpoint gets no push; its record waits", ctx do
      endpoint = endpoint!(ctx)
      agent = agent!(ctx, %{})
      record = append!(ctx, agent.mailbox)

      assert push!(ctx, agent.mailbox, record) == []
      assert message(ctx, endpoint, record) == nil

      mailbox = F.body(F.request(:get, "/v1/agents/" <> agent["id"], ctx.token), 200)["mailbox"]
      assert mailbox["id"] == agent["mailbox"]["id"]
    end
  end

  describe "AG-42 AG-46 the task state of a push comes from the mapping table" do
    test "AG-46: an open question is INPUT_REQUIRED and a resolved waitpoint lets the waiter work" do
      open = A2a.status_update(row(%{}))["statusUpdate"]
      assert open["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
      assert "wp_" <> _ = open["taskId"]
      assert open["metadata"]["relay"]["rule"] == "state"

      resolved = A2a.status_update(row(%{"waitpoint_state" => "resolved"}))["statusUpdate"]
      assert resolved["status"]["state"] == "TASK_STATE_WORKING"

      guardian = %{"waitpoint_kind" => "review", "waitpoint_profile" => "guardian_approval"}
      invitation = A2a.status_update(row(guardian))

      assert invitation["statusUpdate"]["status"]["state"] == "TASK_STATE_AUTH_REQUIRED"
    end

    test "AG-46: Relay claims no task state for a stalled, expired or cancelled waitpoint" do
      for {state, rule} <- [
            {"stalled", "unchanged"},
            {"expired", "owner_decides"},
            {"cancelled", "owner_decides"}
          ] do
        update = A2a.status_update(row(%{"waitpoint_state" => state}))["statusUpdate"]
        assert update["status"]["state"] == "TASK_STATE_UNSPECIFIED"
        assert update["metadata"]["relay"]["rule"] == rule
      end
    end

    test "AG-42: a push names the record and its position and carries neither content nor sender" do
      update = A2a.status_update(row(%{}))["statusUpdate"]
      assert Map.keys(update) == ~w(contextId metadata status taskId)
      assert Map.keys(update["status"]) == ~w(state timestamp)
      assert Map.keys(update["metadata"]) == ~w(relay seq)
    end
  end

  describe "AG-42 E-50 reading A2A" do
    test "AG-42: a StreamResponse holds exactly one event and names its task and sequence" do
      status = %{"state" => "TASK_STATE_COMPLETED", "timestamp" => "2026-11-17T10:00:00Z"}
      update = %{"taskId" => "task-1", "contextId" => "ctx-1", "status" => status}

      assert {:ok, %{task: "task-1", state: "TASK_STATE_COMPLETED", seq: 1_794_909_600_000_000}} =
               A2a.notification(%{"statusUpdate" => update})

      numbered = Map.put(update, "metadata", %{"seq" => 4})
      assert {:ok, %{seq: 4}} = A2a.notification(%{"statusUpdate" => numbered})

      assert {:ok, %{task: "task-1", state: nil, seq: 9}} =
               A2a.notification(%{
                 "artifactUpdate" => %{"taskId" => "task-1", "metadata" => %{"seq" => 9}}
               })

      assert {:ok, %{task: "task-1"}} = A2a.task(%{"id" => "task-1", "status" => status})

      assert A2a.notification(%{"statusUpdate" => update, "task" => %{}}) == :error
      assert A2a.notification(%{"statusUpdate" => Map.delete(update, "taskId")}) == :error
      unknown = put_in(update, ["status", "state"], "done")
      assert A2a.notification(%{"statusUpdate" => unknown}) == :error
      negative = Map.put(update, "metadata", %{"seq" => -1})
      assert A2a.notification(%{"statusUpdate" => negative}) == :error
      assert A2a.notification([]) == :error
    end

    test "E-50: A2A-Version is one value of a served version" do
      assert Relay.Agents.a2a_version(["1.0"]) == {:ok, "1.0"}
      assert Relay.Agents.a2a_version([]) == {:error, :version_not_supported}
      assert Relay.Agents.a2a_version(["0.3"]) == {:error, :version_not_supported}
      assert Relay.Agents.a2a_version(["1.0", "1.0"]) == {:error, :version_not_supported}
    end
  end
end
