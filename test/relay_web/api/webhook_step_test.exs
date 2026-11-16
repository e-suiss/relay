defmodule RelayWeb.Api.WebhookStepTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Profile
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @url "https://hooks.example.com/shop"
  @hour 3_600_000

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{tenant: tenant, scope: scope, token: F.token(scope)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp consumer!(ctx) do
    key = "shop-" <> TenantFixture.random()
    post(ctx, "/v1/webhook_consumers", %{"key" => key, "source" => "urn:shop:" <> key}, 201)
  end

  defp event_type!(ctx, name, required) do
    body = %{
      "name" => name,
      "schema" => %{
        "type" => "object",
        "required" => [required],
        "properties" => %{
          "order" => %{"type" => "string"},
          "note" => %{"type" => "string"},
          "flag" => %{"type" => "boolean"}
        }
      },
      "identifiers" => ["order"]
    }

    post(ctx, "/v1/webhook_event_types", body, 201)
  end

  defp endpoint!(ctx, consumer, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "use" => "destination",
          "consumer" => consumer["key"],
          "destination" => %{"kind" => "https", "url" => @url},
          "event_types" => ["order.shipped"]
        },
        overrides
      )

    created = post(ctx, "/v1/webhook_endpoints", body, 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp mail(key),
    do: %{"type" => "channel", "key" => key, "channel" => "email", "template" => "order-shipped"}

  defp hook(consumer_key, type \\ "order.shipped"),
    do: %{"type" => "webhook", "key" => "hook", "endpoint" => consumer_key, "event_type" => type}

  defp workflow!(ctx, key, steps) do
    definition = Map.put(F.definition(), "steps", steps)
    :ok = F.category_of!(ctx.token, definition)
    :ok = F.template!(ctx.scope, "order-shipped", definition["category"])

    created =
      F.request(:post, "/v1/workflows", ctx.token, %{"key" => key, "definition" => definition})

    assert created.status == 201, created.resp_body
    F.publish!(ctx.scope, ctx.token, key)
  end

  defp send!(ctx, key, data, recipients \\ 1) do
    to =
      for _n <- 1..recipients do
        %{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}
      end

    body = %{"workflow" => key, "to" => to, "data" => data}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)

    for %{"notification_id" => notification} <- accepted["notifications"] do
      {:ok, id} = Relay.ExternalId.decode(notification, ["ntf"])
      id
    end
  end

  defp run!(ctx, id) do
    {:ok, run} = Relay.Workflow.run(ctx.scope, id)
    run
  end

  defp emitted!(ctx, id) do
    assert %{"outcome" => "emitted", "webhook_event_id" => text} =
             run!(ctx, id)["step_results"]["hook"]

    {:ok, event_id} = Relay.Id.parse(text)
    event_id
  end

  defp read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  defp message(ctx, endpoint, event_id),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, event_id) end)

  defp stored(ctx, event_id) do
    sql = """
    SELECT e.use_kind, e.origin, e.event_type, e.payload, e.payload_ct, e.source
    FROM relay.webhook_events e WHERE e.id = $1
    """

    read(ctx, fn ->
      %{rows: [row], columns: columns} = Repo.scoped_query!(sql, [event_id])
      columns |> Enum.zip(row) |> Map.new()
    end)
  end

  defp delivery do
    assert_received {:webhook_delivery, config, prepared, _opts}
    {config, prepared}
  end

  defp jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp advance!(ctx, ms) do
    assert {:ok, {:advanced, _, _}} =
             VirtualClock.advance(ctx.scope, ms, TenantFixture.digest(), TenantFixture.actor())
  end

  describe "WF-8 WF-11 the webhook step" do
    test "WF-8, WF-11, WH-1, WH-13: the step delivers the event to the consumer's subscribed endpoints through the engine",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx, "order.shipped", "order")
      thin = endpoint!(ctx, consumer)
      wide = endpoint!(ctx, consumer, %{"snapshot" => ["note"]})
      deaf = endpoint!(ctx, consumer, %{"event_types" => []})
      other = endpoint!(ctx, consumer!(ctx))
      workflow!(ctx, "ship", [hook(consumer["key"]), mail("mail")])

      [id] = send!(ctx, "ship", %{"order" => "A-1", "note" => "fragile"})

      assert [%{worker: Webhooks.AttemptWorker}, %{worker: Webhooks.AttemptWorker}] = jobs()
      event_id = emitted!(ctx, id)
      assert message(ctx, deaf, event_id) == nil
      assert message(ctx, other, event_id) == nil

      event = stored(ctx, event_id)
      assert %{"use_kind" => "destination", "origin" => "workflow"} = event
      assert %{"event_type" => "order.shipped", "payload" => nil} = event
      assert event["source"] == consumer["source"]
      refute event["payload_ct"] =~ "fragile"

      first = message(ctx, thin, event_id)
      assert %{"state" => "pending", "origin" => "event", "endpoint_version" => 1} = first
      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, first["id"])
      {config, prepared} = delivery()
      assert config == %{url: @url}

      body = Jason.decode!(prepared.body)
      assert %{"specversion" => "1.0", "type" => "order.shipped"} = body
      assert body["id"] == prepared.id
      assert body["source"] == consumer["source"]
      assert body["data"] == %{"order" => "A-1"}

      second = message(ctx, wide, event_id)
      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, second["id"])
      {_config, snapshot} = delivery()
      assert snapshot.id == prepared.id
      assert Jason.decode!(snapshot.body)["data"] == %{"order" => "A-1", "note" => "fragile"}

      {:ok, delivered} = Webhooks.get_message(ctx.scope, first["id"])
      assert %{"state" => "delivered", "attempt_count" => 1} = delivered
    end

    test "WH-4, WH-5, WH-8 (4): a delivery to a consumer is signed with the endpoint's key and carries no identifier of the tenant",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx, "order.shipped", "order")
      endpoint = endpoint!(ctx, consumer)
      workflow!(ctx, "signed", [hook(consumer["key"]), mail("mail")])

      [id] = send!(ctx, "signed", %{"order" => "A-2"})
      message = message(ctx, endpoint, emitted!(ctx, id))
      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, message["id"])
      {_config, prepared} = delivery()

      [key] = endpoint["signing_keys"]
      {:ok, public} = Profile.parse_key(key["public_key"])
      now = Relay.Clock.utc_now()
      %{id: id, headers: headers, body: raw} = prepared
      assert {:ok, %{id: ^id}} = Profile.verify(headers, raw, [public], now, 300)

      body = Jason.decode!(prepared.body)
      refute Map.has_key?(body, "accesstenant")
      refute Map.has_key?(body, "accessorganization")
      refute prepared.body =~ Relay.Id.to_string(ctx.scope.tenant_id)
      assert body["source"] == consumer["source"]
    end

    test "WH-2, INV-12: the runs of one accepted event deliver one event, whatever the number of recipients",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx, "order.shipped", "order")
      endpoint = endpoint!(ctx, consumer)
      workflow!(ctx, "many", [hook(consumer["key"]), mail("mail")])

      [one, two] = send!(ctx, "many", %{"order" => "A-3"}, 2)

      assert [%{worker: Webhooks.AttemptWorker}] = jobs()
      event_id = emitted!(ctx, one)
      assert emitted!(ctx, two) == event_id
      assert %{"state" => "pending"} = message(ctx, endpoint, event_id)
    end

    test "WF-11: a later condition reads the delivery result of the step and the consumer's answer never enters the run",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx, "order.shipped", "order")
      endpoint = endpoint!(ctx, consumer)

      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{
            "when" => %{"eq" => [%{"var" => "steps.hook.delivered"}, true]},
            "steps" => [mail("thanks")]
          }
        ],
        "else" => [mail("late")]
      }

      wait = %{"type" => "delay", "key" => "wait", "duration" => "PT1H"}
      workflow!(ctx, "checked", [hook(consumer["key"]), wait, check])

      [reached] = send!(ctx, "checked", %{"order" => "A-4"})
      [missed] = send!(ctx, "checked", %{"order" => "A-5"})
      Fake.answers([Fake.http(200, [], "the-answer-of-the-consumer"), Fake.http(500)])

      delivered = message(ctx, endpoint, emitted!(ctx, reached))
      failing = message(ctx, endpoint, emitted!(ctx, missed))
      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, delivered["id"])
      assert {:ok, {:attempted, :scheduled}} = Webhooks.attempt(ctx.scope, failing["id"])

      advance!(ctx, @hour + 60_000)
      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, run!(ctx, reached)["id"])
      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, run!(ctx, missed)["id"])

      run = run!(ctx, reached)
      assert Map.has_key?(run["step_results"], "thanks")
      refute Map.has_key?(run["step_results"], "late")
      refute inspect(run) =~ "the-answer-of-the-consumer"

      results = run!(ctx, missed)["step_results"]
      assert Map.has_key?(results, "late")
      refute Map.has_key?(results, "thanks")
    end

    test "WF-11, WH-13, WH-43 (2): an event that cannot be emitted is recorded as skipped with its reason and the run goes on",
         ctx do
      consumer = consumer!(ctx)
      event_type!(ctx, "order.flagged", "flag")
      endpoint!(ctx, consumer, %{"event_types" => ["*"]})
      workflow!(ctx, "nobody", [hook("nobody-here", "order.flagged"), mail("mail")])
      workflow!(ctx, "untyped", [hook(consumer["key"], "order.unknown"), mail("mail")])
      workflow!(ctx, "unfit", [hook(consumer["key"], "order.flagged"), mail("mail")])

      for {key, reason} <- [
            {"nobody", "consumer_not_found"},
            {"untyped", "event_type_not_found"},
            {"unfit", "payload_invalid"}
          ] do
        [id] = send!(ctx, key, %{"order" => "A-6"})
        run = run!(ctx, id)

        assert %{
                 "outcome" => "skipped",
                 "rule_id" => "workflow_run.step_unavailable",
                 "reason" => ^reason
               } = run["step_results"]["hook"]

        refute Map.has_key?(run["step_results"]["hook"], "webhook_event_id")

        assert %{"state" => "completed"} = run
        assert [_delivery] = run["step_results"]["mail"]["deliveries"]
      end

      assert jobs() == []
    end
  end
end
