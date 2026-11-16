defmodule Relay.Webhooks.BatcherTest do
  use Relay.DataCase, async: false

  import RelayTest.WebhookDestinations

  alias Relay.Webhooks
  alias Relay.Webhooks.Batcher
  alias Relay.Webhooks.BatchStore
  alias Relay.Webhooks.BatchWorker
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.Health
  alias RelayTest.DestinationFixture, as: Net
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @host "relay-events.s3.eu-central-1.amazonaws.com"
  @secret "store-secret-value-0123456789"
  @wide %{max_age_ms: 300_000, max_bytes: 16_777_216, max_events: 10_000}

  setup do
    previous = install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    ctx = %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
    credential = credential!(ctx.scope, @secret)
    on_exit(fn -> System.delete_env(credential.var) end)
    Map.merge(ctx, %{credential: credential, endpoint: store!(ctx, credential.id)})
  end

  defp store!(ctx, credential_id) do
    endpoint!(ctx, %{
      "kind" => "s3",
      "bucket" => "relay-events",
      "region" => "eu-central-1",
      "prefix" => "events",
      "access_key_id" => "AKIDEXAMPLE0000000",
      "credential_ref_id" => credential_id
    })
  end

  defp limits(overrides), do: Map.merge(@wide, overrides)

  defp joined!(ctx, count, limits) do
    pairs = for _n <- 1..count, do: message!(ctx, ctx.endpoint)
    _ = jobs()

    for {_event, message} <- pairs,
        do: assert(:done = attempt(ctx, message, batch_limits: limits))

    pairs
  end

  defp batch_id(%{worker: BatchWorker, args: %{"batch_id" => text}}) do
    {:ok, id} = Relay.Id.parse(text)
    id
  end

  defp batch(ctx, id), do: read(ctx, fn -> BatchStore.batch(id) end)

  defp lines(request), do: String.split(request.body, "\n", trim: true)

  defp webhook_ids(pairs),
    do: Enum.map(pairs, fn {event, _message} -> Relay.ExternalId.encode("oev", event.id) end)

  describe "WH-21 WH-52 batches of an object store endpoint" do
    test "WH-21, WH-52: messages join one batch without using an attempt, the count closes it and it is written once as CloudEvents JSON lines",
         ctx do
      limits = limits(%{max_events: 3})
      [first, second, third] = all = for _n <- 1..3, do: message!(ctx, ctx.endpoint)
      _ = jobs()

      assert :done = attempt(ctx, elem(first, 1), batch_limits: limits)
      assert [%{worker: BatchWorker, scheduled_at: closes_at} = opened] = jobs()
      assert_in_delta DateTime.diff(closes_at, Relay.Clock.utc_now(), :second), 300, 5

      assert :done = attempt(ctx, elem(second, 1), batch_limits: limits)
      assert jobs() == []
      assert sent() == []

      waiting = message(ctx, ctx.endpoint, elem(first, 0))
      assert %{"state" => "pending", "attempt_count" => 0, "total_attempt_count" => 0} = waiting
      assert attempts(ctx, waiting) == []
      id = batch_id(opened)
      assert %{"state" => "open", "event_count" => 2} = batch(ctx, id)
      assert {:ok, {:retry_in, seconds}} = Webhooks.write_batch(ctx.scope, id)
      assert seconds > 200

      assert :done = attempt(ctx, elem(third, 1), batch_limits: limits)
      assert [%{worker: BatchWorker, scheduled_at: at} = closed] = jobs()
      assert batch_id(closed) == id
      assert DateTime.diff(at, Relay.Clock.utc_now(), :second) < 5
      assert %{"state" => "closed", "event_count" => 3} = batch(ctx, id)

      assert {:ok, {:written, :delivered, 3}} = Webhooks.write_batch(ctx.scope, id)
      assert [{%{host: @host, port: 443}, request}] = sent()
      name = Relay.ExternalId.encode("whb", id)
      assert %{method: "PUT", path: path} = request
      assert path == "/events/" <> name <> ".jsonl"
      assert Net.header(request, "content-type") == "application/x-ndjson"

      events = Enum.map(lines(request), &Jason.decode!/1)
      assert Enum.all?(events, &(&1["specversion"] == "1.0"))
      assert Enum.sort(Enum.map(events, & &1["id"])) == Enum.sort(webhook_ids(all))

      for {event, message} <- all do
        assert %{"state" => "delivered", "attempt_count" => 1} = message(ctx, ctx.endpoint, event)
        assert [%{"attempt_no" => 1, "result" => "succeeded"} = row] = attempts(ctx, message)
        assert row["trigger_kind"] == "schedule"
        assert row["ip"] == "203.0.114.10"
        assert Enum.any?(lines(request), &(:crypto.hash(:sha256, &1) == row["body_digest"]))
      end

      written = batch(ctx, id)
      assert %{"state" => "written", "attempt_count" => 1} = written
      assert written["object_key"] == "events/" <> name <> ".jsonl"
      assert written["object_digest"] == :crypto.hash(:sha256, request.body)
      assert jobs() == []

      assert {:ok, :done} = Webhooks.write_batch(ctx.scope, id)
      assert sent() == []
    end

    test "WH-21, WH-52: an event that no longer fits closes the batch and opens the next, and an event over the size limit is a batch of its own",
         ctx do
      [{_event, first}, {_other, second}, {_large, third}] =
        for _n <- 1..3, do: message!(ctx, ctx.endpoint)

      _ = jobs()

      assert :done = attempt(ctx, first, batch_limits: @wide)
      assert [opened] = jobs()
      %{"byte_count" => bytes} = batch(ctx, batch_id(opened))
      tight = limits(%{max_bytes: bytes + div(bytes, 2)})

      assert :done = attempt(ctx, second, batch_limits: tight)
      assert [closed, next] = jobs()
      assert batch_id(closed) == batch_id(opened)
      assert batch_id(next) != batch_id(opened)
      assert %{"state" => "closed", "event_count" => 1} = batch(ctx, batch_id(closed))
      assert %{"state" => "open", "event_count" => 1} = batch(ctx, batch_id(next))

      assert :done = attempt(ctx, third, batch_limits: limits(%{max_bytes: 16}))
      assert [full, alone] = jobs()
      assert batch_id(full) == batch_id(next)
      assert %{"state" => "closed", "event_count" => 1} = batch(ctx, batch_id(alone))
      assert DateTime.diff(alone.scheduled_at, Relay.Clock.utc_now(), :second) < 5
    end

    test "WH-21, WH-52: the age closes a batch: it is written when its time has come", ctx do
      pairs = joined!(ctx, 2, @wide)
      assert [job] = jobs()
      id = batch_id(job)

      assert {:ok, {:retry_in, _seconds}} = Webhooks.write_batch(ctx.scope, id)
      assert %{"state" => "open"} = batch(ctx, id)
      late = [clock: at(301)]
      assert {:ok, {:written, :delivered, 2}} = Webhooks.write_batch(ctx.scope, id, late)
      assert [{_connection, request}] = sent()
      assert length(lines(request)) == 2
      assert %{"state" => "written"} = batch(ctx, id)

      for {event, _message} <- pairs,
          do: assert(%{"state" => "delivered"} = message(ctx, ctx.endpoint, event))
    end

    test "WH-45 (3), WH-32: a test event and a resend are written at once as an object of one line",
         ctx do
      path = "/v1/webhook_endpoints/#{ctx.endpoint["id"]}/test"
      created = F.body(F.request(:post, path, ctx.token, %{}), 202)
      {:ok, id} = Relay.ExternalId.decode(created["id"], ["whm"])

      assert {:ok, {:attempted, :delivered}} = Webhooks.attempt(ctx.scope, id)
      assert [{%{host: @host}, request}] = sent()
      assert request.path == "/events/" <> created["event_id"] <> ".jsonl"
      assert [line] = lines(request)
      assert %{"type" => "webhook_endpoint.tested"} = Jason.decode!(line)

      [{event, message}] = joined!(ctx, 1, @wide)
      assert {:attempted, :delivered} = attempt(ctx, message, manual: true)
      assert [{_connection, resent}] = sent()
      assert resent.path == "/events/" <> Relay.ExternalId.encode("oev", event.id) <> ".jsonl"
      assert %{"state" => "delivered"} = message(ctx, ctx.endpoint, event)
    end
  end

  describe "WH-18 WH-19 WH-35 WH-37 the write of a batch" do
    test "WH-18, WH-35: a write the store refuses for now settles every member for a retry, fails the batch and tells the endpoint's health once",
         ctx do
      one = limits(%{max_events: 1})
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [_opened, closed] = jobs()
      id = batch_id(closed)
      Net.answer(@host, Net.response(503, "<Error/>"))

      assert {:ok, {:written, :retry, 2}} = Webhooks.write_batch(ctx.scope, id)
      assert %{"state" => "failed", "object_key" => nil} = batch(ctx, id)

      for {event, message} <- pairs do
        assert %{"state" => "scheduled", "attempt_count" => 1} = message(ctx, ctx.endpoint, event)
        assert [%{"result" => "failed_retryable"} = row] = attempts(ctx, message)
        assert row["failure_code"] == "destination_unavailable"
      end

      retries = jobs()
      assert Enum.count(retries, &(&1.worker == Webhooks.AttemptWorker)) == 2
      health = read(ctx, fn -> EngineStore.health(ctx.endpoint.uuid) end)
      assert %{"consecutive_failures" => 1, "failure_count" => 1} = health

      Net.answer(@host, Net.response(200))
      [{_event, again} | _rest] = pairs
      assert :done = attempt(ctx, again, clock: at(120), batch_limits: one)
      assert [next] = jobs()
      next_id = batch_id(next)
      assert next_id != id
      late = [clock: at(121)]
      assert {:ok, {:written, :delivered, 1}} = Webhooks.write_batch(ctx.scope, next_id, late)
      assert [%{"attempt_no" => 1}, %{"attempt_no" => 2} = last] = attempts(ctx, again)
      assert last["result"] == "succeeded"
    end

    test "WH-19: the credential is resolved from its reference for the write alone and reaches no job, no attempt record and no batch row",
         ctx do
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [opened, closed] = jobs()
      id = batch_id(closed)
      refute inspect([opened, closed]) =~ @secret

      System.delete_env(ctx.credential.var)
      assert {:ok, {:written, :retry, 2}} = Webhooks.write_batch(ctx.scope, id)
      assert sent() == []
      [{_event, message} | _rest] = pairs
      assert [%{"failure_code" => "credentials_unavailable"}] = attempts(ctx, message)

      System.put_env(ctx.credential.var, @secret)
      one = limits(%{max_events: 1})
      assert :done = attempt(ctx, message, clock: at(120), batch_limits: one)
      jobs = jobs()
      next_id = jobs |> Enum.find(&(&1.worker == BatchWorker)) |> batch_id()
      late = [clock: at(121)]
      assert {:ok, {:written, :delivered, 1}} = Webhooks.write_batch(ctx.scope, next_id, late)
      assert [{_connection, request}] = sent()
      signed = Net.header(request, "authorization")
      assert signed =~ "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE0000000/"

      refute inspect(request) =~ @secret
      refute inspect(jobs) =~ @secret
      refute inspect(attempts(ctx, message)) =~ @secret
      refute inspect(batch(ctx, next_id)) =~ @secret
      refute inspect(read(ctx, fn -> EngineStore.endpoint(ctx.endpoint.uuid) end)) =~ @secret
    end

    test "WH-35 (2): a write behind an open circuit breaker waits for the breaker and is the probe that closes it",
         ctx do
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [_opened, closed] = jobs()
      id = batch_id(closed)
      now = Relay.Clock.utc_now()

      open = %{
        "breaker_state" => "open",
        "breaker_opened_at" => now,
        "breaker_open_seconds" => 30,
        "breaker_retry_at" => DateTime.add(now, 30, :second),
        "breaker_trips" => 1,
        "consecutive_failures" => 5
      }

      read(ctx, fn ->
        health = Map.merge(EngineStore.health(ctx.endpoint.uuid), open)
        EngineStore.health_save(ctx.endpoint.uuid, Health.columns(health), now)
      end)

      assert {:ok, :done} = Webhooks.write_batch(ctx.scope, id)
      assert sent() == []
      assert [%{worker: BatchWorker, scheduled_at: at} = again] = jobs()
      assert batch_id(again) == id
      assert_in_delta DateTime.diff(at, now, :second), 30, 3
      assert %{"state" => "closed", "attempt_count" => 0} = batch(ctx, id)

      for {event, _message} <- pairs,
          do: assert(%{"state" => "pending"} = message(ctx, ctx.endpoint, event))

      late = [clock: at(31)]
      assert {:ok, {:written, :delivered, 2}} = Webhooks.write_batch(ctx.scope, id, late)
      health = read(ctx, fn -> EngineStore.health(ctx.endpoint.uuid) end)
      assert %{"breaker_state" => "closed", "consecutive_failures" => 0} = health
    end

    test "WH-37: the members of a batch whose endpoint was paused are held, never dropped", ctx do
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [_opened, closed] = jobs()
      path = "/v1/webhook_endpoints/#{ctx.endpoint["id"]}/pause"
      assert %{"state" => "paused"} = F.body(F.request(:post, path, ctx.token, nil), 200)

      assert {:ok, :done} = Webhooks.write_batch(ctx.scope, batch_id(closed))
      assert sent() == []
      assert %{"state" => "failed"} = batch(ctx, batch_id(closed))

      for {event, _message} <- pairs do
        held = message(ctx, ctx.endpoint, event)
        assert %{"state" => "held", "hold_reason" => "endpoint_paused"} = held
        assert held["attempt_count"] == 0
      end
    end
  end

  describe "WH-21 WH-32 a crashed write" do
    test "WH-21, WH-32 (4): a write that crashed is queued again and writes the same object under the same name",
         ctx do
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [_opened, closed] = jobs()
      id = batch_id(closed)
      Net.answer(@host, fn _request -> raise "the writer crashed" end)

      assert_raise RuntimeError, fn -> Webhooks.write_batch(ctx.scope, id) end
      assert [{_connection, first}] = sent()
      assert %{"state" => "closed", "attempt_count" => 1} = batch(ctx, id)

      for {event, _message} <- pairs,
          do: assert(%{"state" => "in_flight"} = message(ctx, ctx.endpoint, event))

      Net.answer(@host, Net.response(200))
      assert {:ok, {:retry_in, _seconds}} = Webhooks.write_batch(ctx.scope, id)
      assert sent() == []

      later = DateTime.add(Relay.Clock.utc_now(), 700, :second)
      assert read(ctx, fn -> Batcher.requeue_overdue(later) end) == 1
      assert [%{worker: BatchWorker} = rescued] = jobs()
      assert batch_id(rescued) == id

      late = [clock: at(700)]
      assert {:ok, {:written, :delivered, 2}} = Webhooks.write_batch(ctx.scope, id, late)
      assert [{_connection, second}] = sent()
      assert second.path == first.path
      assert second.body == first.body
      assert %{"state" => "written", "attempt_count" => 2} = batch(ctx, id)

      for {event, message} <- pairs do
        assert %{"state" => "delivered", "attempt_count" => 1} = message(ctx, ctx.endpoint, event)
        assert [%{"result" => "succeeded"}] = attempts(ctx, message)
      end
    end

    test "WH-21, WH-32 (4): the sweep leaves the members of a waiting batch to the batch", ctx do
      pairs = joined!(ctx, 2, limits(%{max_events: 2}))
      assert [_opened, closed] = jobs()
      id = batch_id(closed)
      now = Relay.Clock.utc_now()
      until = DateTime.add(now, 1, :millisecond)
      token = Relay.Id.generate()

      claim = fn -> BatchStore.claim(id, token, until, now) end
      assert {:claimed, [_one, _two]} = read(ctx, claim)
      Process.sleep(20)

      assert {:ok, %{rescued: 0, requeued: 0, batches: 0}} = Webhooks.sweep_scope(ctx.scope)
      assert jobs() == []

      for {event, _message} <- pairs,
          do: assert(%{"state" => "in_flight"} = message(ctx, ctx.endpoint, event))

      assert {:ok, {:written, :delivered, 2}} = Webhooks.write_batch(ctx.scope, id)
      assert %{"state" => "written", "attempt_count" => 2} = batch(ctx, id)
    end
  end
end
