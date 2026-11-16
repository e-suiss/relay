defmodule Relay.Webhooks.EngineTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Profile
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @url "https://hooks.example.com/relay"

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp patch(ctx, path, body, status),
    do: F.body(F.request(:patch, path, ctx.token, body), status)

  defp get(ctx, path), do: F.body(F.request(:get, path, ctx.token), 200)

  defp endpoint!(ctx, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "use" => "relay_events",
          "destination" => %{"kind" => "https", "url" => @url},
          "event_types" => ["notification.delivered"]
        },
        overrides
      )

    created = post(ctx, "/v1/webhook_endpoints", body, 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["whe"])
    Map.put(created, :uuid, id)
  end

  defp uuid, do: Relay.Id.to_string(Relay.Id.generate())

  defp payload(extra \\ %{}) do
    Map.merge(
      %{
        "notification_id" => uuid(),
        "delivery_id" => uuid(),
        "recipient_id" => uuid(),
        "recipient_kind" => "subscriber",
        "workflow" => %{"key" => "welcome", "version" => 1},
        "channel" => "email",
        "delivered_at" => "2026-11-16T10:00:00Z"
      },
      extra
    )
  end

  defp outbox(type \\ "notification.delivered", payload \\ payload()) do
    %{
      id: Relay.Id.generate(),
      created_at: Relay.Clock.utc_now(),
      event_type: type,
      stream_key: "notification:" <> uuid(),
      epoch: 1,
      seq: 1,
      payload: payload,
      traceparent: nil
    }
  end

  defp dispatch!(ctx, event) do
    {:ok, []} = Repo.in_scope(ctx.scope, fn _status -> Webhooks.Live.outbox_jobs(event) end)
    event
  end

  defp read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  defp message(ctx, endpoint, event),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, event.id) end)

  defp stored_event(ctx, event), do: read(ctx, fn -> EngineStore.event(event.id) end)

  defp attempts(ctx, message) do
    sql = """
    SELECT a.attempt_no, a.trigger_kind, a.result, a.failure_code, a.response_status,
      a.webhook_timestamp, a.signature, host(a.destination_ip) AS ip, a.body_digest,
      a.response_ct, a.retry_after_seconds
    FROM relay.webhook_attempts a WHERE a.message_id = $1 ORDER BY a.attempt_no
    """

    read(ctx, fn ->
      %{rows: rows, columns: columns} = Repo.scoped_query!(sql, [message["id"]])
      Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
    end)
  end

  defp attempt(ctx, message, opts \\ []) do
    {:ok, result} = Webhooks.attempt(ctx.scope, message["id"], opts)
    result
  end

  defp at(seconds), do: fn -> DateTime.add(Relay.Clock.utc_now(), seconds, :second) end

  defp delivery do
    assert_received {:webhook_delivery, config, prepared, opts}
    {config, prepared, opts}
  end

  defp jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "WH-2 INV-12 WH-16 fan-out" do
    test "WH-2, INV-12, OP-7: one event is one row and one message per subscribed endpoint, and dispatching it again creates nothing",
         ctx do
      first = endpoint!(ctx)
      second = endpoint!(ctx)
      event = dispatch!(ctx, outbox())

      assert [%{worker: Webhooks.AttemptWorker}, %{worker: Webhooks.AttemptWorker}] = jobs()
      assert %{"state" => "pending", "origin" => "event"} = one = message(ctx, first, event)
      assert %{"state" => "pending"} = message(ctx, second, event)

      dispatch!(ctx, event)
      assert jobs() == []
      assert message(ctx, first, event)["id"] == one["id"]
    end

    test "WH-16: an endpoint receives only the types it chose, nothing with an empty selection and everything with an explicit *",
         ctx do
      chosen = endpoint!(ctx, %{"event_types" => ["notification.failed"]})
      none = endpoint!(ctx, %{"event_types" => []})
      all = endpoint!(ctx, %{"event_types" => ["*"]})
      event = dispatch!(ctx, outbox())

      assert message(ctx, chosen, event) == nil
      assert message(ctx, none, event) == nil
      assert %{"state" => "pending"} = message(ctx, all, event)
    end

    test "WH-53: an event type outside the catalog is never recorded or delivered", ctx do
      endpoint = endpoint!(ctx, %{"event_types" => ["*"]})
      event = dispatch!(ctx, outbox("internal.thing_happened", %{"a" => 1}))

      assert stored_event(ctx, event) == nil
      assert message(ctx, endpoint, event) == nil
    end

    test "WH-11: the stored payload is the thin event: only the catalog's identifiers, with external identifiers",
         ctx do
      endpoint!(ctx)
      body = payload(%{"internal_note" => "never leaves"})
      event = dispatch!(ctx, outbox("notification.delivered", body))

      stored = stored_event(ctx, event)["payload"]
      refute Map.has_key?(stored, "internal_note")
      refute Map.has_key?(stored, "recipient_kind")
      assert "ntf_" <> _rest = stored["notification_id"]
      assert "sub_" <> _rest = stored["recipient_id"]
    end

    test "WH-11: the free text of a messaging interaction never reaches the stored event", ctx do
      endpoint!(ctx, %{"event_types" => ["messaging_interaction.received"]})

      body = %{
        "channel" => "slack",
        "kind" => "message",
        "provider_event_id" => "Ev1",
        "provider_user_id" => "U1",
        "text" => "my card number is 4111",
        "action" => "typed"
      }

      event = dispatch!(ctx, outbox("messaging_interaction.received", body))

      assert stored_event(ctx, event)["payload"] == %{
               "channel" => "slack",
               "kind" => "message",
               "provider_event_id" => "Ev1"
             }
    end

    test "WH-37, INV-3, INV-4: an event for a paused or disabled endpoint becomes a held message and is never dropped",
         ctx do
      paused = endpoint!(ctx)
      disabled = endpoint!(ctx)
      post(ctx, "/v1/webhook_endpoints/#{paused["id"]}/pause", nil, 200)
      patch(ctx, "/v1/webhook_endpoints/#{disabled["id"]}", %{"state" => "disabled"}, 200)
      _ = jobs()

      event = dispatch!(ctx, outbox())

      assert jobs() == []

      assert %{"state" => "held", "hold_reason" => "endpoint_paused"} =
               message(ctx, paused, event)

      assert %{"state" => "held", "hold_reason" => "endpoint_disabled"} =
               message(ctx, disabled, event)
    end

    test "WH-34 (2): a disabled endpoint does not receive its own disable event", ctx do
      own = endpoint!(ctx, %{"event_types" => ["*"]})
      other = endpoint!(ctx, %{"event_types" => ["*"]})
      body = %{"endpoint_id" => own["id"], "reason" => "gone"}
      event = dispatch!(ctx, outbox("webhook_endpoint.disabled", body))

      assert message(ctx, own, event) == nil
      assert %{"state" => "pending"} = message(ctx, other, event)
    end
  end

  describe "WH-4 WH-7 WH-9 WH-10 the attempt" do
    test "WH-4, WH-7, WH-9, WH-10, WH-19: an attempt is signed over its body with a new timestamp and logged without a secret",
         ctx do
      endpoint = endpoint!(ctx)
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)
      Fake.answers([Fake.http(500, [], "down"), Fake.http(200, [], "stored")])

      assert {:attempted, :scheduled} = attempt(ctx, message)
      {config, first, opts} = delivery()
      assert config == %{url: @url}
      assert opts[:connect_timeout_ms] == 5_000
      assert opts[:total_timeout_ms] == 20_000
      assert opts[:max_response_bytes] == 8192

      assert {:attempted, :delivered} = attempt(ctx, message, clock: at(60))
      {_config, second, _opts} = delivery()

      assert first.body == second.body
      assert first.id == second.id
      assert first.id == Relay.ExternalId.encode("oev", event.id)
      assert first.attempt == 1 and second.attempt == 2
      assert %{"id" => id, "type" => "notification.delivered"} = Jason.decode!(first.body)
      assert id == first.id

      [key] = endpoint["signing_keys"]
      {:ok, public} = Profile.parse_key(key["public_key"])
      headers = Map.new(second.headers)
      now = DateTime.from_unix!(String.to_integer(headers["webhook-timestamp"]))
      assert {:ok, %{id: ^id}} = Profile.verify(second.headers, second.body, [public], now, 300)
      refute Map.new(first.headers)["webhook-timestamp"] == headers["webhook-timestamp"]
      refute Enum.any?(second.headers, fn {name, _value} -> name == "webhook-attempt" end)

      assert [one, two] = attempts(ctx, message)
      assert %{"attempt_no" => 1, "result" => "failed_retryable"} = one
      assert one["failure_code"] == "http_5xx"
      assert %{"attempt_no" => 2, "result" => "succeeded", "response_status" => 200} = two
      assert two["ip"] == "203.0.114.7"
      assert two["signature"] == headers["webhook-signature"]
      assert two["body_digest"] == :crypto.hash(:sha256, second.body)
      assert is_binary(two["response_ct"]) and not (two["response_ct"] =~ "stored")
      assert %{"state" => "delivered", "attempt_count" => 2} = message(ctx, endpoint, event)
    end

    test "WH-12, API-55: the body follows the endpoint version the message is pinned to, whatever the API version",
         ctx do
      types = %{"event_types" => ["notification.suppressed"], "snapshot" => ["metadata"]}
      endpoint = endpoint!(ctx, types)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      body = payload(%{"reason" => "quiet_hours", "rule_id" => "policy.quiet_hours"})
      event = dispatch!(ctx, outbox("notification.suppressed", body))
      message = message(ctx, endpoint, event)
      refute Map.has_key?(stored_event(ctx, event)["payload"], "metadata")
      Process.put(:webhook_source, %{"metadata" => %{"plan" => "pro"}, "outside" => "no"})

      patch(ctx, path, %{"snapshot" => []}, 200)
      assert message["endpoint_version"] == 1
      assert {:attempted, :delivered} = attempt(ctx, message)
      {_config, prepared, _opts} = delivery()
      data = Jason.decode!(prepared.body)["data"]
      assert data["metadata"] == %{"plan" => "pro"}
      refute Map.has_key?(data, "outside")
      assert get(ctx, path)["payload_version"] == endpoint["payload_version"]
    end
  end

  describe "WH-22 WH-23 WH-25 WH-27 outcomes" do
    test "WH-23, WH-27: a redirect is not followed and not retried, and an abort ends the message",
         ctx do
      endpoint = endpoint!(ctx)
      redirected = message(ctx, endpoint, dispatch!(ctx, outbox()))
      aborted = message(ctx, endpoint, dispatch!(ctx, outbox()))
      abort = [{"webhook-delivery", "abort-message"}]
      Fake.answers([Fake.http(302, [{"location", "https://x.example"}]), Fake.http(500, abort)])

      assert {:attempted, :failed_permanent} = attempt(ctx, redirected)
      assert {:attempted, :failed_permanent} = attempt(ctx, aborted)

      {:ok, one} = Webhooks.get_message(ctx.scope, redirected["id"])
      {:ok, two} = Webhooks.get_message(ctx.scope, aborted["id"])
      assert %{"state" => "failed_permanent", "reason" => "redirect_not_followed"} = one
      assert %{"state" => "failed_permanent", "reason" => "aborted_by_consumer"} = two
      assert [%{"result" => "aborted"}] = attempts(ctx, aborted)
      assert length(Enum.filter(jobs(), &(&1.worker == Webhooks.AttemptWorker))) == 2
    end

    test "WH-23, WH-36 (2), WH-34: a 410 fails the message for good and disables the endpoint at once",
         ctx do
      endpoint = endpoint!(ctx)
      message = message(ctx, endpoint, dispatch!(ctx, outbox()))
      _ = jobs()
      Fake.answers([Fake.http(410)])

      assert {:attempted, :failed_permanent} = attempt(ctx, message)

      assert %{"state" => "disabled", "disabled_reason" => "gone"} =
               get(ctx, "/v1/webhook_endpoints/#{endpoint["id"]}")

      assert [%{worker: Webhooks.NoticeWorker, args: %{"kind" => "endpoint_disabled"}}] = jobs()
      next = message(ctx, endpoint, dispatch!(ctx, outbox()))
      assert %{"state" => "held", "hold_reason" => "endpoint_disabled"} = next
    end

    test "WH-22, WH-27, WH-34: a message whose schedule ends is exhausted and reported", ctx do
      endpoint = endpoint!(ctx, %{"retry_schedule" => ["PT0S", "PT1M"]})
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)
      _ = jobs()
      Fake.answers([Fake.failure(:timeout), Fake.http(503)])

      assert {:attempted, :scheduled} = attempt(ctx, message)
      assert [%{worker: Webhooks.AttemptWorker, scheduled_at: next}] = jobs()
      wait = DateTime.diff(next, Relay.Clock.utc_now(), :second)
      assert wait in 47..73
      assert :done = attempt(ctx, message)

      assert {:attempted, :exhausted} = attempt(ctx, message, clock: at(120))
      assert %{"state" => "exhausted", "attempt_count" => 2} = message(ctx, endpoint, event)
      assert [%{worker: Webhooks.NoticeWorker, args: %{"kind" => "attempt_exhausted"}}] = jobs()
    end

    test "WH-25: a Retry-After longer than the schedule defers the message without using an attempt, at most three times",
         ctx do
      endpoint = endpoint!(ctx, %{"retry_schedule" => ["PT0S", "PT1M", "PT1M", "PT1M"]})
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)
      slow = Fake.http(429, [{"retry-after", "600"}])
      Fake.answers([slow, slow, slow, slow])

      for n <- 0..2 do
        assert {:attempted, :scheduled} = attempt(ctx, message, clock: at(n * 601))
      end

      assert %{"attempt_count" => 0, "retry_after_count" => 3} = message(ctx, endpoint, event)
      assert {:attempted, :scheduled} = attempt(ctx, message, clock: at(3 * 601))
      assert %{"attempt_count" => 1, "retry_after_count" => 3} = message(ctx, endpoint, event)

      assert ["deferred", "deferred", "deferred", "failed_retryable"] =
               Enum.map(attempts(ctx, message), & &1["result"])
    end
  end

  describe "WH-32 WH-35 WH-38 isolation" do
    test "WH-32 (4): a message is attempted by one attempt at a time", ctx do
      endpoint = endpoint!(ctx)
      message = message(ctx, endpoint, dispatch!(ctx, outbox()))
      token = Relay.Id.generate()
      now = Relay.Clock.utc_now()
      until = DateTime.add(now, 60, :second)

      assert {:claimed, nil} =
               read(ctx, fn -> EngineStore.claim(message["id"], token, until, false, now) end)

      assert {:retry_in, seconds} = attempt(ctx, message)
      assert seconds in 1..60
      assert {:retry_in, _seconds} = attempt(ctx, message, manual: true)
      refute_received {:webhook_delivery, _config, _prepared, _opts}
    end

    test "WH-32 (1), WH-32 (2): a failed resend leaves state and schedule, a successful one delivers and cancels the waiting attempts",
         ctx do
      endpoint = endpoint!(ctx)
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)
      Fake.answers([Fake.http(500), Fake.http(500), Fake.http(200)])

      assert {:attempted, :scheduled} = attempt(ctx, message)
      before = message(ctx, endpoint, event)
      assert {:attempted, :unchanged} = attempt(ctx, message, manual: true)
      failed = message(ctx, endpoint, event)
      assert failed["state"] == "scheduled"
      assert failed["attempt_count"] == before["attempt_count"]
      assert failed["next_attempt_at"] == before["next_attempt_at"]

      assert {:attempted, :delivered} = attempt(ctx, message, manual: true)
      assert_received {:webhook_cancel, id}
      assert id == message["id"]
      triggers = Enum.map(attempts(ctx, message), & &1["trigger_kind"])
      assert triggers == ["schedule", "manual", "manual"]
    end

    test "WH-38: a rate limited or busy endpoint postpones its message without using an attempt",
         ctx do
      slow = endpoint!(ctx)
      event = dispatch!(ctx, outbox())
      message = message(ctx, slow, event)
      _ = jobs()

      Process.put(:webhook_rate, {:deny, 3_000})
      assert :done = attempt(ctx, message)
      Process.put(:webhook_rate, :allow)
      Process.put(:webhook_slot, {:full, 2_000})
      assert :done = attempt(ctx, message, clock: at(10))
      Process.delete(:webhook_slot)

      refute_received {:webhook_delivery, _config, _prepared, _opts}
      assert [%{worker: Webhooks.AttemptWorker}, %{worker: Webhooks.AttemptWorker}] = jobs()

      assert %{"state" => "pending", "attempt_count" => 0, "total_attempt_count" => 0} =
               message(ctx, slow, event)

      assert {:attempted, :delivered} = attempt(ctx, message, clock: at(30))
    end

    test "WH-35: five failures in a row open the breaker; messages wait without using attempts and one probe closes it",
         ctx do
      endpoint = endpoint!(ctx)
      events = for _n <- 1..7, do: dispatch!(ctx, outbox())
      messages = Enum.map(events, &message(ctx, endpoint, &1))
      Fake.answers(List.duplicate(Fake.failure(:connect), 5))

      for message <- Enum.take(messages, 5) do
        assert {:attempted, :scheduled} = attempt(ctx, message)
      end

      health = get(ctx, "/v1/webhook_endpoints/#{endpoint["id"]}/health")
      assert %{"state" => "open"} = health["breaker"]
      assert health["failed"] == 5 and health["success_rate_bp"] == 0
      assert [%{"code" => "connection_failed", "count" => 5}] = health["recent_failures"]

      waiting = Enum.at(messages, 5)
      _ = jobs()
      for _n <- 1..5, do: delivery()
      assert :done = attempt(ctx, waiting)
      refute_received {:webhook_delivery, _config, _prepared, _opts}

      assert %{"state" => "held", "hold_reason" => "breaker_open", "attempt_count" => 0} =
               message(ctx, endpoint, Enum.at(events, 5))

      assert [%{worker: Webhooks.ReleaseWorker}] = jobs()
      late = dispatch!(ctx, outbox())
      assert %{"state" => "held", "hold_reason" => "breaker_open"} = message(ctx, endpoint, late)

      probe = Enum.at(messages, 6)
      assert {:attempted, :delivered} = attempt(ctx, probe, clock: at(31))
      closed = get(ctx, "/v1/webhook_endpoints/#{endpoint["id"]}/health")
      assert %{"state" => "closed", "retry_at" => nil} = closed["breaker"]
      assert Enum.any?(jobs(), &(&1.worker == Webhooks.ReleaseWorker))

      assert {:ok, 2} = Webhooks.release_held(ctx.scope, endpoint.uuid, "breaker_open", 100)
      assert %{"state" => "pending"} = message(ctx, endpoint, late)
    end
  end

  describe "WH-31 WH-39 WH-45 endpoint operations" do
    test "WH-31, WH-37: a paused endpoint holds its messages and a resume releases them", ctx do
      endpoint = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)

      assert %{"state" => "paused"} = post(ctx, path <> "/pause", nil, 200)
      assert %{"state" => "paused"} = post(ctx, path <> "/pause", nil, 200)
      assert :done = attempt(ctx, message)
      held = message(ctx, endpoint, event)
      assert %{"state" => "held", "hold_reason" => "endpoint_paused"} = held

      assert %{"state" => "active"} = post(ctx, path <> "/resume", nil, 200)
      assert {:ok, 1} = Webhooks.release_held(ctx.scope, endpoint.uuid, "endpoint_paused", 100)
      assert %{"state" => "pending"} = message(ctx, endpoint, event)
      assert {:attempted, :delivered} = attempt(ctx, message, clock: at(5))
    end

    test "WH-45 (3): a test event goes to the one endpoint, is attempted once and stays out of its health",
         ctx do
      endpoint = endpoint!(ctx, %{"event_types" => []})
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"

      sent = post(ctx, path <> "/test", %{}, 202)
      assert %{"origin" => "test", "state" => "pending"} = sent
      assert sent["event_type"] == "webhook_endpoint.tested"

      {:ok, id} = Relay.ExternalId.decode(sent["id"], ["whm"])
      Fake.answers([Fake.http(500)])
      assert {:ok, {:attempted, :exhausted}} = Webhooks.attempt(ctx.scope, id)
      {_config, prepared, _opts} = delivery()
      assert prepared.id == sent["event_id"]
      assert get(ctx, path <> "/health")["failed"] == 1
      assert get(ctx, path <> "/health")["failing_since"] == nil
    end

    test "WH-31, WH-33 (1): a replay to another endpoint and a restart keep the event identifier",
         ctx do
      first = endpoint!(ctx)
      other = endpoint!(ctx, %{"event_types" => []})
      event = dispatch!(ctx, outbox())
      message = message(ctx, first, event)
      Fake.answers([Fake.http(404)])
      assert {:attempted, :failed_permanent} = attempt(ctx, message)

      replayed = read(ctx, fn -> Webhooks.replay_event(event.id, other.uuid) end)
      assert %{"origin" => "replay", "state" => "pending"} = copy = message(ctx, other, event)
      assert copy["id"] == replayed
      assert read(ctx, fn -> Webhooks.replay_event(event.id, other.uuid) end) == nil

      assert read(ctx, fn -> Webhooks.restart_messages([message["id"]]) end) == 1
      restarted = message(ctx, first, event)
      assert %{"state" => "pending", "schedule_no" => 2, "attempt_count" => 0} = restarted

      assert {:attempted, :delivered} = attempt(ctx, message)
      {_config, prepared, _opts} = delivery()
      assert prepared.id == Relay.ExternalId.encode("oev", event.id)
      triggers = Enum.map(attempts(ctx, message), & &1["trigger_kind"])
      assert triggers == ["schedule", "recovery"]

      assert read(ctx, fn -> Webhooks.cancel_messages([copy["id"]], "tester") end) == 1
      assert %{"state" => "cancelled"} = message(ctx, other, event)
    end
  end

  describe "WH-28 WH-56 sweep and notices" do
    test "OP-8: print the engine functions" do
      Repo.query!("SET search_path = pg_catalog")

      rows =
        Repo.query!("""
        SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid)
          || ') -> ' || pg_get_function_result(p.oid) || ' | ' || pg_get_userbyid(p.proowner)
          || ' | ' || COALESCE(array_to_string(p.proconfig, '; '), '')
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.proname LIKE 'webhook\\_%' AND p.proname NOT LIKE 'webhook\\_receipt%'
        ORDER BY 1
        """).rows

      IO.puts(Enum.map_join(rows, "\n", fn [line] -> "GOLDEN " <> line end))
    end

    test "WH-32 (4), WH-28: the sweep picks up a message whose worker crashed", ctx do
      endpoint = endpoint!(ctx)
      event = dispatch!(ctx, outbox())
      message = message(ctx, endpoint, event)
      now = Relay.Clock.utc_now()
      until = DateTime.add(now, 1, :millisecond)
      token = Relay.Id.generate()

      assert {:claimed, nil} =
               read(ctx, fn -> EngineStore.claim(message["id"], token, until, false, now) end)

      Process.sleep(20)
      _ = jobs()
      assert {:ok, %{rescued: 1}} = Webhooks.sweep_scope(ctx.scope)
      assert [%{worker: Webhooks.AttemptWorker}] = jobs()
      assert %{"state" => "pending"} = message(ctx, endpoint, event)
      assert {:attempted, :delivered} = attempt(ctx, message)
    end

    test "WH-56: without a configured sender or a contact the operations e-mail is skipped as operations_email_unavailable",
         ctx do
      endpoint = endpoint!(ctx)
      handler = "operations-email-#{inspect(self())}"
      test = self()

      :telemetry.attach(
        handler,
        [:relay, :webhooks, :operations_email],
        fn _event, _measurements, meta, _config -> send(test, {:operations_email, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = Webhooks.NoticeWorker.deliver(ctx.scope, "endpoint_disabled", endpoint.uuid)
      assert_received {:operations_email, %{result: :skipped, reason: reason}}
      assert reason == :operations_email_unavailable
      refute_received {:webhook_mail, _addresses, _mail}
    end
  end
end
