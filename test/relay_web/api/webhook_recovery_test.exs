defmodule RelayWeb.Api.WebhookRecoveryTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Webhooks
  alias Relay.Webhooks.EngineStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @url "https://hooks.example.com/relay"
  @messages "/v1/webhook_messages"

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)

  defp patch(ctx, path, body, status),
    do: F.body(F.request(:patch, path, ctx.token, body), status)

  defp get(ctx, path, status \\ 200), do: F.body(F.request(:get, path, ctx.token), status)

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

  defp outbox do
    %{
      id: Relay.Id.generate(),
      created_at: Relay.Clock.utc_now(),
      event_type: "notification.delivered",
      stream_key: "notification:" <> uuid(),
      epoch: 1,
      seq: 1,
      payload: %{
        "notification_id" => uuid(),
        "delivery_id" => uuid(),
        "recipient_id" => uuid(),
        "recipient_kind" => "subscriber",
        "workflow" => %{"key" => "welcome", "version" => 1},
        "channel" => "email",
        "delivered_at" => "2026-11-16T10:00:00Z"
      },
      traceparent: nil
    }
  end

  defp dispatch!(ctx) do
    event = outbox()
    {:ok, []} = Repo.in_scope(ctx.scope, fn _status -> Webhooks.Live.outbox_jobs(event) end)
    event
  end

  defp read(ctx, fun) do
    {:ok, value} = Repo.in_scope(ctx.scope, fn _status -> fun.() end)
    value
  end

  defp message(ctx, endpoint, event),
    do: read(ctx, fn -> EngineStore.message_of(endpoint.uuid, event.id) end)

  defp message!(ctx, endpoint), do: message(ctx, endpoint, dispatch!(ctx))

  defp attempt(ctx, message, opts \\ []) do
    {:ok, result} = Webhooks.attempt(ctx.scope, message["id"], opts)
    result
  end

  defp failed!(ctx, message) do
    Fake.answers([Fake.http(404)])
    assert {:attempted, :failed_permanent} = attempt(ctx, message)
    message
  end

  defp whm(message), do: Relay.ExternalId.encode("whm", message["id"])
  defp oev(event), do: Relay.ExternalId.encode("oev", event.id)
  defp shown(ctx, message), do: get(ctx, @messages <> "/" <> whm(message))
  defp listed(ctx, query), do: get(ctx, @messages <> "?" <> URI.encode_query(query))["data"]
  defp hour_ago, do: DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), -3_600, :second))
  defp in_an_hour, do: DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 3_600, :second))

  defp jobs(acc \\ []) do
    receive do
      {:webhook_job, job} -> jobs([job | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp recoveries, do: Enum.filter(jobs(), &(&1.worker == Webhooks.RecoveryWorker))

  defp run!(%{worker: worker, args: args}) do
    stored = args |> Jason.encode!() |> Jason.decode!()
    assert :ok = worker.perform(%Oban.Job{args: stored})
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
        )
      end)

    for row <- rows, do: Map.take(row, ~w(actor_kind target_type target_id))
  end

  describe "WH-30 delivery log" do
    test "WH-30 (3), API-56: the delivery log pages the messages newest first and filters them",
         ctx do
      first = endpoint!(ctx)
      _second = endpoint!(ctx, %{"event_types" => ["*"]})
      events = for _n <- 1..3, do: dispatch!(ctx)

      page = get(ctx, @messages <> "?limit=4")
      assert %{"object" => "list", "has_more" => true, "next_cursor" => cursor} = page
      rest = get(ctx, @messages <> "?limit=4&starting_after=" <> URI.encode_www_form(cursor))
      assert %{"has_more" => false, "previous_cursor" => previous} = rest
      ids = Enum.map(page["data"] ++ rest["data"], & &1["id"])
      assert length(Enum.uniq(ids)) == 6
      assert ids == Enum.sort(ids, :desc)
      back = get(ctx, @messages <> "?limit=4&ending_before=" <> URI.encode_www_form(previous))
      assert Enum.map(back["data"], & &1["id"]) == Enum.take(ids, 4)

      own = listed(ctx, %{"endpoint_id" => first["id"]})
      assert length(own) == 3
      assert Enum.all?(own, &(&1["endpoint_id"] == first["id"]))
      event_id = oev(hd(events))

      assert [%{"event_id" => ^event_id}, %{"event_id" => ^event_id}] =
               listed(ctx, %{"event_id" => event_id})

      assert length(listed(ctx, %{"state" => "pending"})) == 6
      assert listed(ctx, %{"state" => "delivered"}) == []
      assert length(listed(ctx, %{"event_type" => "notification.delivered"})) == 6
      assert listed(ctx, %{"event_type" => "notification.suppressed"}) == []
      assert listed(ctx, %{"created_after" => in_an_hour()}) == []
      assert length(listed(ctx, %{"created_before" => in_an_hour()})) == 6
      assert listed(ctx, %{"created_before" => hour_ago()}) == []

      refused = get(ctx, @messages <> "?state=lost&endpoint_id=nope", 422)
      assert Enum.sort(Enum.map(refused["errors"], & &1["pointer"])) == ["/endpoint_id", "/state"]

      assert {:attempted, :delivered} = attempt(ctx, message(ctx, first, hd(events)))
      assert [%{"attempt_count" => 1} = delivered] = listed(ctx, %{"state" => "delivered"})
      assert delivered["delivered_at"]
      assert get(ctx, @messages <> "/" <> delivered["id"]) == delivered

      missing = Relay.ExternalId.encode("whm", Relay.Id.generate())
      assert get(ctx, @messages <> "/" <> missing, 404)["code"] == "webhook_message_not_found"
    end

    test "WH-10, WH-19, WH-30: attempts are listed in attempt order without their answers, and one attempt carries its answer only while that is kept",
         ctx do
      endpoint = endpoint!(ctx, %{"signature_scheme" => "v1"})
      assert "whsec_" <> _ = secret = endpoint["secret"]
      message = message!(ctx, endpoint)
      Fake.answers([Fake.http(500, [], "upstream down"), Fake.http(200, [], <<255, 0>>)])
      assert {:attempted, :scheduled} = attempt(ctx, message)
      assert {:attempted, :delivered} = attempt(ctx, message, manual: true)
      path = "#{@messages}/#{whm(message)}/attempts"

      all = get(ctx, path)
      assert %{"has_more" => false, "data" => [one, two]} = all
      assert %{"object" => "webhook_attempt", "attempt_no" => 1, "trigger" => "schedule"} = one
      assert %{"result" => "failed_retryable", "failure_code" => "http_5xx"} = one
      assert one["response_status"] == 500
      assert %{"attempt_no" => 2, "trigger" => "manual", "result" => "succeeded"} = two
      assert one["destination_ip"] == "203.0.114.7"
      assert "v1," <> _ = one["signature"]
      refute Map.has_key?(one, "response_body")
      refute Jason.encode!(all) =~ secret

      head = get(ctx, path <> "?limit=1")
      assert %{"has_more" => true, "data" => [^one], "next_cursor" => cursor} = head
      tail = get(ctx, path <> "?limit=1&starting_after=" <> URI.encode_www_form(cursor))
      assert %{"has_more" => false, "data" => [^two], "previous_cursor" => previous} = tail
      back = get(ctx, path <> "?limit=1&ending_before=" <> URI.encode_www_form(previous))
      assert [^one] = back["data"]

      first = get(ctx, path <> "/" <> one["id"])
      assert Map.delete(first, "response_body") == one

      assert first["response_body"] ==
               %{"encoding" => "utf8", "content" => "upstream down", "truncated" => false}

      second = get(ctx, path <> "/" <> two["id"])
      raw = Base.encode64(<<255, 0>>)

      assert second["response_body"] ==
               %{"encoding" => "base64", "content" => raw, "truncated" => false}

      refute Jason.encode!([first, second]) =~ secret

      {:ok, attempt_id} = Relay.ExternalId.decode(one["id"], ["wha"])
      later = DateTime.add(Relay.Clock.utc_now(), 31 * 86_400, :second)

      assert {:ok, %{"response" => %{truncated: false}}} =
               Webhooks.get_attempt(ctx.scope, message["id"], attempt_id)

      assert {:ok, %{"response" => nil, "attempt_no" => 1}} =
               Webhooks.DeliveryLog.attempt(ctx.scope, message["id"], attempt_id, later)

      other = message!(ctx, endpoint)
      foreign = "#{@messages}/#{whm(other)}/attempts"
      assert get(ctx, foreign)["data"] == []
      assert get(ctx, foreign <> "/" <> one["id"], 404)["code"] == "webhook_attempt_not_found"
      missing = Relay.ExternalId.encode("whm", Relay.Id.generate())
      unknown = get(ctx, "#{@messages}/#{missing}/attempts", 404)
      assert unknown["code"] == "webhook_message_not_found"
    end
  end

  describe "WH-31 WH-32 one message" do
    test "WH-31, WH-32, WH-33 (1), WH-48: a resend queues one manual attempt with the same event identifier and is audited",
         ctx do
      endpoint = endpoint!(ctx)
      event = dispatch!(ctx)
      message = message(ctx, endpoint, event)
      _ = jobs()
      path = "#{@messages}/#{whm(message)}/resend"
      key = F.key()

      sent = F.body(F.request(:post, path, ctx.token, nil, [key]), 202)
      assert %{"state" => "pending", "attempt_count" => 0} = sent
      assert sent["event_id"] == oev(event)
      assert [%{worker: Webhooks.AttemptWorker, args: %{"manual" => true}}] = jobs()

      again = F.request(:post, path, ctx.token, nil, [key])
      assert F.body(again, 202) == sent
      assert Plug.Conn.get_resp_header(again, "idempotency-replayed") == ["true"]
      assert jobs() == []

      assert [%{"target_type" => "webhook_message", "target_id" => target}] =
               audit(ctx.scope, "webhook_message.resent")

      assert target == Relay.Id.to_string(message["id"])

      Fake.answers([Fake.http(500)])
      assert {:attempted, :unchanged} = attempt(ctx, message, manual: true)
      assert %{"state" => "pending", "attempt_count" => 1} = shown(ctx, message)
      assert {:attempted, :delivered} = attempt(ctx, message, manual: true)
      assert %{"state" => "delivered", "attempt_count" => 2} = shown(ctx, message)
      assert sent["event_id"] == shown(ctx, message)["event_id"]
    end

    test "WH-32 (4), WH-31: a message whose attempt runs is neither resent nor cancelled, and an endpoint that is not active takes no resend",
         ctx do
      endpoint = endpoint!(ctx)
      busy = message!(ctx, endpoint)
      idle = message!(ctx, endpoint)
      now = Relay.Clock.utc_now()
      until = DateTime.add(now, 60, :second)
      claim = fn -> EngineStore.claim(busy["id"], Relay.Id.generate(), until, false, now) end
      assert {:claimed, _at} = read(ctx, claim)

      resend = post(ctx, "#{@messages}/#{whm(busy)}/resend", nil, 409)
      assert resend["code"] == "webhook_message_in_flight"
      cancel = post(ctx, "#{@messages}/#{whm(busy)}/cancel", nil, 409)
      assert cancel["code"] == "webhook_message_in_flight"
      assert %{"state" => "in_flight"} = shown(ctx, busy)

      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      post(ctx, path <> "/pause", nil, 200)
      paused = post(ctx, "#{@messages}/#{whm(idle)}/resend", nil, 422)
      assert paused["code"] == "webhook_endpoint_state_conflict"
      post(ctx, path <> "/archive", nil, 200)
      archived = post(ctx, "#{@messages}/#{whm(idle)}/resend", nil, 422)
      assert archived["code"] == "webhook_endpoint_archived"
      assert audit(ctx.scope, "webhook_message.resent") == []

      missing = Relay.ExternalId.encode("whm", Relay.Id.generate())
      unknown = post(ctx, "#{@messages}/#{missing}/resend", nil, 404)
      assert unknown["code"] == "webhook_message_not_found"
    end

    test "WH-31, WH-27, WH-48: cancelling a message ends its waiting attempts as cancelled, and a terminal message comes back unchanged",
         ctx do
      endpoint = endpoint!(ctx)
      message = message!(ctx, endpoint)
      path = "#{@messages}/#{whm(message)}/cancel"

      cancelled = post(ctx, path, nil, 200)
      assert %{"state" => "cancelled", "reason" => "cancelled"} = cancelled
      assert cancelled["next_attempt_at"] == nil
      assert_received {:webhook_cancel, id}
      assert id == message["id"]
      assert post(ctx, path, nil, 200) == cancelled
      refute_received {:webhook_cancel, _id}

      assert [%{"target_id" => target}] = audit(ctx.scope, "webhook_message.cancelled")
      assert target == Relay.Id.to_string(message["id"])
      assert :done = attempt(ctx, message)
      assert shown(ctx, message) == cancelled
    end
  end

  describe "WH-31 WH-33 endpoint recovery" do
    test "WH-31, WH-32 (3), WH-33 (1), WH-48: recover queues again what failed since a time, in a job, with the same event identifier",
         ctx do
      endpoint = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      failed = failed!(ctx, message!(ctx, endpoint))
      cancelled = message!(ctx, endpoint)
      post(ctx, "#{@messages}/#{whm(cancelled)}/cancel", nil, 200)
      delivered = message!(ctx, endpoint)
      assert {:attempted, :delivered} = attempt(ctx, delivered)
      waiting = message!(ctx, endpoint)
      _ = jobs()

      missed = get(ctx, path <> "/missed_events")["data"]
      assert Enum.sort(Enum.map(missed, & &1["id"])) == Enum.sort([whm(failed), whm(cancelled)])

      assert post(ctx, path <> "/recover", %{"since" => in_an_hour()}, 200)["selected"] == 0
      at = hour_ago()
      late = %{"since" => at, "until" => at}
      assert [%{"pointer" => "/until"}] = post(ctx, path <> "/recover", late, 422)["errors"]
      _ = jobs()

      recovery = post(ctx, path <> "/recover", %{"since" => hour_ago()}, 200)

      assert recovery == %{
               "object" => "webhook_recovery",
               "operation" => "recover",
               "endpoint_id" => endpoint["id"],
               "selected" => 2
             }

      assert %{"state" => "failed_permanent"} = shown(ctx, failed)
      assert [%{args: args} = job] = jobs()

      assert Enum.sort(Map.keys(args)) ==
               ~w(actor_ref cursor endpoint_id environment event_types operation reasons since
                  states tenant_id until)

      run!(job)
      jobs = jobs()
      assert length(Enum.filter(jobs, &(&1.worker == Webhooks.AttemptWorker))) == 2
      assert Enum.filter(jobs, &(&1.worker == Webhooks.RecoveryWorker)) == []

      before = shown(ctx, failed)
      assert %{"state" => "pending", "reason" => nil, "attempt_count" => 1} = before
      assert %{"state" => "pending"} = shown(ctx, cancelled)
      assert %{"state" => "delivered"} = shown(ctx, delivered)
      assert %{"state" => "pending", "attempt_count" => 0} = shown(ctx, waiting)
      assert get(ctx, path <> "/missed_events")["data"] == []

      assert {:attempted, :delivered} = attempt(ctx, failed)
      again = shown(ctx, failed)
      assert %{"state" => "delivered", "attempt_count" => 2} = again
      assert again["event_id"] == before["event_id"]
      attempts = get(ctx, "#{@messages}/#{whm(failed)}/attempts")["data"]

      assert Enum.map(attempts, &{&1["attempt_no"], &1["trigger"]}) ==
               [{1, "schedule"}, {2, "recovery"}]

      audited = audit(ctx.scope, "webhook_endpoint.messages_recovered")
      assert length(audited) == 2
      assert Enum.all?(audited, &(&1["target_id"] == Relay.Id.to_string(endpoint.uuid)))
    end

    test "WH-37, WH-30 (2), WH-31: the events a disabled endpoint missed are kept, listed and recovered once it is enabled again",
         ctx do
      endpoint = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      gone = message!(ctx, endpoint)
      Fake.answers([Fake.http(410)])
      assert {:attempted, :failed_permanent} = attempt(ctx, gone)
      assert %{"state" => "disabled"} = get(ctx, path)
      kept = message!(ctx, endpoint)
      assert %{"state" => "held", "hold_reason" => "endpoint_disabled"} = shown(ctx, kept)

      missed = get(ctx, path <> "/missed_events?event_type=notification.delivered")["data"]
      assert Enum.map(missed, & &1["id"]) == [whm(kept), whm(gone)]
      assert get(ctx, path <> "/missed_events?created_after=" <> in_an_hour())["data"] == []

      assert [%{"pointer" => "/created_after"}] =
               get(ctx, path <> "/missed_events?created_after=soon", 422)["errors"]

      unknown = Relay.ExternalId.encode("whe", Relay.Id.generate())
      absent = get(ctx, "/v1/webhook_endpoints/#{unknown}/missed_events", 404)
      assert absent["code"] == "webhook_endpoint_not_found"

      refused = post(ctx, path <> "/recover", %{"since" => hour_ago()}, 422)
      assert refused["code"] == "webhook_endpoint_state_conflict"
      assert audit(ctx.scope, "webhook_endpoint.messages_recovered") == []

      assert %{"state" => "active"} = patch(ctx, path, %{"state" => "active"}, 200)
      _ = jobs()
      assert post(ctx, path <> "/recover", %{"since" => hour_ago()}, 200)["selected"] == 2
      [job] = recoveries()
      run!(job)
      assert %{"state" => "pending", "hold_reason" => nil} = shown(ctx, kept)
      assert %{"state" => "pending"} = shown(ctx, gone)
      assert {:attempted, :delivered} = attempt(ctx, kept)
    end

    test "WH-31, WH-32 (3): a bulk retry restarts only the messages that match every filter",
         ctx do
      endpoint = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}/retry"
      failed = failed!(ctx, message!(ctx, endpoint))
      cancelled = message!(ctx, endpoint)
      post(ctx, "#{@messages}/#{whm(cancelled)}/cancel", nil, 200)
      reason = shown(ctx, failed)["reason"]
      _ = jobs()

      select = fn body -> post(ctx, path, body, 200)["selected"] end
      assert select.(%{"since" => hour_ago()}) == 2
      assert select.(%{"states" => ["cancelled"]}) == 1
      assert select.(%{"reasons" => [reason]}) == 1
      assert select.(%{"states" => ["cancelled"], "reasons" => [reason]}) == 0
      assert select.(%{"event_types" => ["notification.suppressed"]}) == 0
      assert select.(%{"event_types" => ["notification.delivered"], "until" => hour_ago()}) == 0
      assert post(ctx, path, %{}, 422)["code"] == "validation_failed"
      assert post(ctx, path, %{"states" => ["delivered"]}, 422)["code"] == "validation_failed"

      [_all, only_cancelled | _rest] = recoveries()
      assert only_cancelled.args["states"] == ["cancelled"]
      run!(only_cancelled)
      assert %{"state" => "pending"} = shown(ctx, cancelled)
      assert %{"state" => "failed_permanent"} = shown(ctx, failed)
      assert length(audit(ctx.scope, "webhook_endpoint.messages_retried")) == 6
    end

    test "WH-31, WH-33 (1), WH-48: a replay delivers the kept events since a time to an endpoint that has no message for them",
         ctx do
      first = endpoint!(ctx)
      events = [dispatch!(ctx), dispatch!(ctx)]
      post(ctx, "/v1/webhook_endpoints/#{first["id"]}/test", %{}, 202)
      added = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{added["id"]}/replay"
      _ = jobs()

      assert post(ctx, path, %{"since" => in_an_hour()}, 200)["selected"] == 0
      other = %{"since" => hour_ago(), "event_types" => ["notification.suppressed"]}
      assert post(ctx, path, other, 200)["selected"] == 0
      assert post(ctx, path, %{}, 422)["code"] == "validation_failed"
      _ = jobs()

      replay = post(ctx, path, %{"since" => hour_ago()}, 200)
      assert %{"operation" => "replay", "selected" => 2} = replay
      assert listed(ctx, %{"endpoint_id" => added["id"]}) == []
      [job] = recoveries()
      run!(job)

      copies = listed(ctx, %{"endpoint_id" => added["id"]})
      assert [%{"origin" => "replay", "state" => "pending"}, %{"origin" => "replay"}] = copies
      assert Enum.sort(Enum.map(copies, & &1["event_id"])) == Enum.sort(Enum.map(events, &oev/1))
      assert length(Enum.filter(jobs(), &(&1.worker == Webhooks.AttemptWorker))) == 2

      assert post(ctx, path, %{"since" => hour_ago()}, 200)["selected"] == 0
      assert length(audit(ctx.scope, "webhook_endpoint.events_replayed")) == 4
    end

    test "WH-31, WH-27, WH-48: cancelling scheduled retries ends the waiting messages of the endpoint at once and leaves the others",
         ctx do
      endpoint = endpoint!(ctx)
      other = endpoint!(ctx)
      path = "/v1/webhook_endpoints/#{endpoint["id"]}/cancel_retries"
      event = dispatch!(ctx)
      waiting = message(ctx, endpoint, event)
      elsewhere = message(ctx, other, event)
      delivered = message!(ctx, endpoint)
      assert {:attempted, :delivered} = attempt(ctx, delivered)
      _ = jobs()

      none = %{"event_types" => ["notification.suppressed"]}
      assert post(ctx, path, none, 200)["selected"] == 0
      assert %{"operation" => "cancel_retries", "selected" => 1} = post(ctx, path, nil, 200)
      assert recoveries() == []
      assert %{"state" => "cancelled", "reason" => "cancelled"} = shown(ctx, waiting)
      assert %{"state" => "delivered"} = shown(ctx, delivered)
      assert %{"state" => "pending"} = shown(ctx, elsewhere)
      assert length(audit(ctx.scope, "webhook_endpoint.retries_cancelled")) == 2

      post(ctx, "/v1/webhook_endpoints/#{endpoint["id"]}/archive", nil, 200)
      assert post(ctx, path, %{}, 422)["code"] == "webhook_endpoint_archived"
    end

    test "WH-33 (2), T-15: an operation larger than one batch goes on in the next job from where it stopped, paced by the endpoint's rate",
         ctx do
      endpoint = endpoint!(ctx, %{"rate_limit_per_second" => 50})
      path = "/v1/webhook_endpoints/#{endpoint["id"]}"
      batch = Webhooks.Recovery.batch()
      for _n <- 1..(batch + 1), do: dispatch!(ctx)
      _ = jobs()
      state = fn state -> length(listed(ctx, %{"state" => state, "limit" => "100"})) end

      assert post(ctx, path <> "/cancel_retries", %{}, 200)["selected"] == batch + 1
      assert [%{args: %{"cursor" => cursor}, scheduled_at: nil} = rest] = recoveries()
      assert is_binary(cursor)
      assert state.("pending") == 1
      run!(rest)
      assert state.("pending") == 0
      assert recoveries() == []

      assert post(ctx, path <> "/recover", %{"since" => hour_ago()}, 200)["selected"] == batch + 1
      [first] = recoveries()
      assert first.args["cursor"] == nil
      run!(first)
      assert state.("cancelled") == 1
      assert [%{scheduled_at: %DateTime{} = at} = second] = recoveries()
      assert DateTime.diff(at, Relay.Clock.utc_now(), :millisecond) > 1_000
      run!(second)
      assert state.("cancelled") == 0
      assert recoveries() == []
    end
  end
end
