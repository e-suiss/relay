defmodule RelayWeb.A2aNotificationTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks.Profile
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @worker "Relay.Webhooks.TaskNotificationWorker"
  @event "agent.task_notification_received"

  defmodule Reader do
    @moduledoc false
    @behaviour Relay.Agents.TaskNotifications

    @impl Relay.Agents.TaskNotifications
    def get_task(_scope, _source_id, task) do
      send(self(), {:get_task, task})
      status = %{"state" => "TASK_STATE_FAILED", "timestamp" => "2026-11-17T10:00:00Z"}
      {:ok, %{"id" => task, "contextId" => "ctx-1", "status" => status}}
    end
  end

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    token = F.token(scope)
    body = %{"name" => "research agent", "public_key" => "whpk_" <> Base.encode64(public_key)}
    source = F.body(F.request(:post, "/v1/webhook_sources", token, body), 201)
    {:ok, source_id} = Relay.ExternalId.decode(source["id"], ["whs"])

    %{scope: scope, token: token, private_key: private_key, source: source, source_id: source_id}
  end

  defp update(task, seq, state) do
    status = %{"state" => state, "timestamp" => "2026-11-17T09:00:00Z"}
    event = %{"taskId" => task, "contextId" => "ctx-1", "status" => status}
    Jason.encode!(%{"statusUpdate" => Map.put(event, "metadata", %{"seq" => seq})})
  end

  defp signed(private_key, id, body) do
    timestamp = DateTime.to_unix(Relay.Clock.utc_now())
    content = Profile.signed_content(id, timestamp, body)
    signature = :crypto.sign(:eddsa, :none, content, [private_key, :ed25519])
    Profile.headers(id, timestamp, [Profile.token(:v1a, signature)])
  end

  defp deliver(ctx, body, headers) do
    tenant = Relay.ExternalId.encode("ten", ctx.scope.tenant_id)
    environment = Atom.to_string(ctx.scope.environment)
    path = "/inbound/v1/a2a/#{tenant}/#{environment}/sources/#{ctx.source["id"]}"
    type = {"content-type", "application/a2a+json"}
    Api.call(Api.conn(:post, path, body, [type | headers]), RelayWeb.Router)
  end

  defp send!(ctx, body, opts \\ []) do
    id = Keyword.get(opts, :id, "msg-" <> TenantFixture.random())
    version = Keyword.get(opts, :version, [{"a2a-version", "1.0"}])
    deliver(ctx, body, version ++ signed(ctx.private_key, id, body))
  end

  defp jobs(scope), do: F.jobs(@worker, scope, "receipt_id")

  defp process(scope, receipts) do
    for [text] <- receipts do
      {:ok, id} = Relay.Id.parse(text)
      {:ok, result} = Relay.Webhooks.process_task_notification(scope, id)
      result
    end
  end

  defp process_new(ctx, before), do: process(ctx.scope, jobs(ctx.scope) -- before)

  defp recorded(ctx, task) do
    {:ok, row} = Relay.Agents.task_notification(ctx.scope, ctx.source_id, task)
    row
  end

  defp announced(scope) do
    sql = "SELECT payload FROM relay.outbox_events WHERE event_type = $1 ORDER BY id"
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, [@event]).rows end)
    Enum.map(rows, fn [payload] -> payload end)
  end

  describe "AG-42 INV-35 E-51 an incoming A2A event is idempotent by task and sequence" do
    test "AG-42: the same task and sequence is acknowledged every time and processed once", ctx do
      body = update("task-1", 1, "TASK_STATE_WORKING")

      assert send!(ctx, body, id: "msg-a").status == 200
      assert send!(ctx, body, id: "msg-b").status == 200
      assert send!(ctx, body, id: "msg-a").status == 200

      assert [_one] = receipts = jobs(ctx.scope)
      assert process(ctx.scope, receipts) == [:applied]
      assert process(ctx.scope, receipts) == [:skipped]

      assert %{"seq" => 1, "state" => "TASK_STATE_WORKING", "protocol" => "a2a"} =
               recorded(ctx, "task-1")

      assert [%{"task" => "task-1", "seq" => 1, "state" => "TASK_STATE_WORKING"} = payload] =
               announced(ctx.scope)

      assert payload["webhook_source_id"] == Relay.Id.to_string(ctx.source_id)
    end

    test "AG-42: A2A-Version is validated before anything is recorded", ctx do
      body = update("task-1", 1, "TASK_STATE_WORKING")

      missing = send!(ctx, body, version: [])
      assert missing.status == 400
      answer = Jason.decode!(missing.resp_body)
      assert %{"error" => "version_not_supported", "supported" => ["1.0"]} = answer

      assert send!(ctx, body, version: [{"a2a-version", "0.3"}]).status == 400
      assert jobs(ctx.scope) == []
      assert recorded(ctx, "task-1") == nil
    end

    test "E-51: a request that does not verify or is no task notification has no effect", ctx do
      body = update("task-1", 1, "TASK_STATE_WORKING")
      {_public, other_key} = :crypto.generate_key(:eddsa, :ed25519)
      version = [{"a2a-version", "1.0"}]

      assert deliver(ctx, body, version ++ signed(other_key, "msg-1", body)).status == 401
      assert deliver(ctx, body, version).status == 401

      assert send!(ctx, Jason.encode!(%{"statusUpdate" => %{"taskId" => "task-1"}})).status == 400
      assert send!(ctx, Jason.encode!(%{"type" => "job.completed"})).status == 400
      assert jobs(ctx.scope) == []
      assert announced(ctx.scope) == []
    end
  end

  describe "AG-37 INV-35 a late notification never overwrites a newer one" do
    test "AG-37: a notification older than the recorded one changes nothing", ctx do
      assert send!(ctx, update("task-2", 5, "TASK_STATE_COMPLETED")).status == 200
      assert process_new(ctx, []) == [:applied]
      before = jobs(ctx.scope)

      assert send!(ctx, update("task-2", 3, "TASK_STATE_WORKING")).status == 200
      assert process_new(ctx, before) == [:stale]

      assert %{"seq" => 5, "state" => "TASK_STATE_COMPLETED", "reconciled_at" => nil} =
               recorded(ctx, "task-2")

      assert [%{"seq" => 5}] = announced(ctx.scope)

      before = jobs(ctx.scope)
      assert send!(ctx, update("task-2", 6, "TASK_STATE_FAILED")).status == 200
      assert process_new(ctx, before) == [:applied]
      assert %{"seq" => 6, "state" => "TASK_STATE_FAILED"} = recorded(ctx, "task-2")
      assert [%{"seq" => 5}, %{"seq" => 6}] = announced(ctx.scope)
    end

    test "AG-37: tasks of one source and of two sources are ordered apart", ctx do
      assert send!(ctx, update("task-a", 9, "TASK_STATE_WORKING")).status == 200
      assert send!(ctx, update("task-b", 2, "TASK_STATE_WORKING")).status == 200
      assert Enum.sort(process_new(ctx, [])) == [:applied, :applied]
      assert %{"seq" => 9} = recorded(ctx, "task-a")
      assert %{"seq" => 2} = recorded(ctx, "task-b")
    end

    test "INV-35: a notification that arrived out of order makes Relay read the task at its source",
         ctx do
      previous = Application.get_env(:relay, Relay.Agents, [])
      Application.put_env(:relay, Relay.Agents, Keyword.put(previous, :task_reader, Reader))
      on_exit(fn -> Application.put_env(:relay, Relay.Agents, previous) end)

      assert send!(ctx, update("task-3", 5, "TASK_STATE_WORKING")).status == 200
      assert process_new(ctx, []) == [:applied]
      refute_received {:get_task, _task}
      before = jobs(ctx.scope)

      assert send!(ctx, update("task-3", 4, "TASK_STATE_SUBMITTED")).status == 200
      assert process_new(ctx, before) == [:stale]
      assert_received {:get_task, "task-3"}

      assert %{"state" => "TASK_STATE_FAILED", "reconciled_at" => %DateTime{}} =
               recorded(ctx, "task-3")
    end

    test "INV-35: without a reader the recorded state stands" do
      scope = TenantFixture.tenant!().test
      source = Relay.Id.generate()
      assert Relay.Agents.reconcile_task(scope, source, "task-9") == {:ok, :unconfigured}
    end
  end

  describe "AG-45 E-54 a protocol notification is no response" do
    test "AG-45: a notification that names a waitpoint as its task neither resolves nor answers it",
         ctx do
      attrs = %{
        id: Relay.Id.generate(),
        kind: :event,
        waiter_kind: :agent,
        waiter_ref: TenantFixture.recipient!(ctx.scope, %{}, kind: :agent),
        match_event_type: "job.finished",
        correlation_key: "job-" <> TenantFixture.random(),
        expires_at: DateTime.add(Relay.Clock.business_now(ctx.scope), 1, :hour)
      }

      {:ok, %{result: :opened, waitpoint_id: id}} = Relay.Agents.open_waitpoint(ctx.scope, attrs)
      task = Relay.ExternalId.encode("wp", id)

      assert send!(ctx, update(task, 1, "TASK_STATE_COMPLETED")).status == 200
      assert process_new(ctx, []) == [:applied]

      assert {:ok, %{state: state}} = Relay.Agents.get_waitpoint(ctx.scope, id)
      assert to_string(state) == "open"
      assert {:ok, nil} = Relay.Agents.waitpoint_completion(ctx.scope, id)
    end
  end
end
