defmodule RelayWeb.Api.EventsTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Repo
  alias Relay.Tenancy.KillSwitch
  alias Relay.Tenancy.KillSwitch.Cache
  alias Relay.Tenancy.KillSwitch.Snapshot
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp send_event(token, body, headers \\ []),
    do: F.request(:post, "/v1/events", token, body, headers)

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "workflow" => "order-shipped",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"}
      },
      overrides
    )
  end

  defp problem(conn, status) do
    body = F.body(conn, status)
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
    body
  end

  defp code(conn, status), do: problem(conn, status)["code"]

  defp get(token, path), do: F.body(F.request(:get, path, token), 200)

  defp post(token, path, body, status), do: F.body(F.request(:post, path, token, body), status)

  defp deliveries(token, notification),
    do: get(token, "/v1/notifications/#{notification}/deliveries")["data"]

  defp accepted(token, overrides \\ %{}), do: F.body(send_event(token, event(overrides)), 202)

  defp first_notification(body) do
    [%{"notification_id" => notification}] = body["notifications"]
    notification
  end

  defp count(scope, sql, params) do
    {:ok, [[n]]} =
      Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)

    n
  end

  describe "API-19 API-20 acceptance" do
    test "API-19: an event is accepted with 202, Location and one notification per recipient",
         ctx do
      conn = send_event(ctx.token, event())
      body = F.body(conn, 202)

      assert body["object"] == "event"
      assert body["status"] == "accepted"
      assert body["workflow"] == %{"key" => "order-shipped", "version" => 1}
      assert body["recipient_count"] == 1

      assert [%{"notification_id" => "ntf_" <> _, "recipient_id" => "sub_" <> _}] =
               body["notifications"]

      assert get_resp_header(conn, "location") == ["/v1/events/" <> body["id"]]
    end

    test "X-35: one request creates the recipient and queues its delivery", ctx do
      notification = first_notification(accepted(ctx.token))

      assert [%{"id" => delivery, "channel" => "email", "status" => "queued"}] =
               deliveries(ctx.token, notification)

      assert [%{"queue" => "l1", "delivery_id" => _}] = F.delivery_jobs(delivery)
    end

    test "OP-7: the event, its notification, delivery and job commit in one transaction", ctx do
      body = accepted(ctx.token)
      {:ok, event_id} = Relay.ExternalId.decode(body["id"], ["evt"])
      notifications = "SELECT count(*) FROM relay.notifications WHERE event_id = $1"

      assert count(ctx.scope, notifications, [event_id]) == 1

      assert count(
               ctx.scope,
               """
               SELECT count(*) FROM relay_queue.oban_jobs j
               JOIN relay.deliveries d ON d.id::text = j.args->>'delivery_id'
               JOIN relay.notifications n ON n.id = d.notification_id
               WHERE n.event_id = $1
               """,
               [event_id]
             ) == 1
    end

    test "WF-7: the notification keeps the workflow version it was accepted with", ctx do
      body = accepted(ctx.token)
      shown = get(ctx.token, "/v1/notifications/" <> first_notification(body))
      assert shown["workflow"] == %{"key" => "order-shipped", "version" => 1}
      assert shown["event_id"] == body["id"]
    end

    test "API-20: an unknown workflow is 404 and an unpublished one is 422", ctx do
      assert problem(send_event(ctx.token, event(%{"workflow" => "nope"})), 404)["code"] ==
               "workflow_not_found"

      created =
        F.request(:post, "/v1/workflows", ctx.token, %{
          "key" => "draft-only",
          "definition" => F.definition()
        })

      assert created.status == 201

      assert problem(send_event(ctx.token, event(%{"workflow" => "draft-only"})), 422)["code"] ==
               "workflow_not_published"
    end

    test "API-27: data outside the event schema is 422 validation_failed and nothing is written",
         ctx do
      events = "SELECT count(*) FROM relay.events"
      before = count(ctx.scope, events, [])
      body = problem(send_event(ctx.token, event(%{"data" => %{"order" => 7}})), 422)

      assert body["code"] == "validation_failed"
      assert Enum.any?(body["errors"], &String.starts_with?(&1["pointer"], "/data"))
      assert count(ctx.scope, events, []) == before
    end

    test "API-20: send_at in the past or beyond 90 days is refused", ctx do
      past = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), -60))
      far = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 91 * 86_400))

      for at <- [past, far] do
        body = problem(send_event(ctx.token, event(%{"send_at" => at})), 422)
        assert body["code"] == "validation_failed"
        assert [%{"pointer" => "/send_at"}] = body["errors"]
      end
    end

    test "API-22: a priority above the class ceiling is clamped with a warning", ctx do
      tenant = ctx.tenant
      F.workflow!(tenant.live, ctx.token, "sale", message_class: "marketing")

      body = accepted(ctx.token, %{"workflow" => "sale", "priority" => "high"})
      assert [%{"code" => "priority_clamped", "pointer" => "/priority"}] = body["warnings"]
    end

    test "API-24: a security subtype needs the security class and an expiry", ctx do
      body = problem(send_event(ctx.token, event(%{"security_subtype" => "otp_oob"})), 422)
      pointers = Enum.map(body["errors"], & &1["pointer"])
      assert "/security_subtype" in pointers
      assert "/expires_at" in pointers
    end

    test "API-23: raw blocks cannot set policy fields", ctx do
      overrides = %{"push" => %{"raw" => %{"interruption_level" => "critical"}}}

      assert problem(send_event(ctx.token, event(%{"overrides" => overrides})), 422)["code"] ==
               "policy_field_not_overridable"
    end

    test "API-26: retention none is refused for the security class", ctx do
      F.workflow!(ctx.scope, ctx.token, "login-code", message_class: "security")

      body =
        problem(
          send_event(ctx.token, event(%{"workflow" => "login-code", "retention" => "none"})),
          422
        )

      assert [%{"pointer" => "/retention"}] = body["errors"]
    end

    test "INV-46: an unknown field is refused with 422 unknown_field", ctx do
      assert problem(send_event(ctx.token, event(%{"colour" => "red"})), 422)["code"] ==
               "unknown_field"
    end
  end

  describe "API-21 recipients" do
    test "API-21: a plain identifier of an unknown subscriber is 422 recipient_not_found", ctx do
      to = ["nobody-" <> TenantFixture.random()]
      body = problem(send_event(ctx.token, event(%{"to" => to})), 422)
      assert body["code"] == "recipient_not_found"
      assert [%{"pointer" => "/to/0"}] = body["errors"]
    end

    test "API-21: an object with only an id opens an inbox-only subscriber", ctx do
      id = "inbox-" <> TenantFixture.random()
      accepted(ctx.token, %{"to" => [%{"id" => id}]})

      subscriber = get(ctx.token, "/v1/subscribers/" <> id)
      assert subscriber["external_id"] == id
      assert subscriber["channels"]["email"] == %{"reachable" => false, "reason" => "no_address"}
    end

    test "API-21: a known subscriber is found by its plain identifier", ctx do
      id = "known-" <> TenantFixture.random()
      accepted(ctx.token, %{"to" => [%{"id" => id, "email" => "k@example.com"}]})
      body = accepted(ctx.token, %{"to" => [id]})
      assert [%{"external_id" => ^id}] = body["notifications"]
    end

    test "X-25: the test environment accepts and upserts recipients the same way", ctx do
      token = F.token(ctx.tenant.test)
      F.workflow!(ctx.tenant.test, token, "order-shipped")
      body = accepted(token)
      assert [%{"recipient_id" => "sub_" <> _}] = body["notifications"]
      assert code(send_event(token, event(%{"to" => ["ghost-1"]})), 422) == "recipient_not_found"
    end
  end

  describe "API-16 deduplication" do
    test "API-16: the same dedup key opens no new notification and names the first event", ctx do
      recipient = %{"id" => "dedup-" <> TenantFixture.random(), "email" => "d@example.com"}
      first = accepted(ctx.token, %{"to" => [recipient], "dedup_key" => "o-1"})
      again = accepted(ctx.token, %{"to" => [recipient], "dedup_key" => "o-1"})
      notification = first_notification(first)

      assert [%{"notification_id" => ^notification, "duplicate_of" => duplicate_of}] =
               again["notifications"]

      assert duplicate_of == first["id"]
    end
  end

  describe "API-13 idempotency" do
    test "API-13: a replay returns the first answer byte for byte", ctx do
      key = F.key()
      body = event()
      first = send_event(ctx.token, body, [key])
      again = send_event(ctx.token, body, [key])

      assert first.status == 202
      assert again.status == 202
      assert again.resp_body == first.resp_body
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
    end
  end

  describe "OP-51 send mode" do
    test "OP-51: send mode off skips the delivery with send_mode_off and queues nothing", ctx do
      {:ok, _} =
        Relay.Tenancy.put_setting(
          ctx.scope,
          %{key: "send_mode.channel.email", value: "off", record_digest: TenantFixture.digest()},
          TenantFixture.actor()
        )

      notification = first_notification(accepted(ctx.token))

      assert [%{"id" => delivery, "status" => "skipped", "reason" => "send_mode_off"}] =
               deliveries(ctx.token, notification)

      assert F.delivery_jobs(delivery) == []
    end

    test "API-62: a per-request send mode is test only; live answers 403", ctx do
      assert problem(send_event(ctx.token, event(%{"send_mode" => "off"})), 403)["code"] ==
               "auth_environment_mismatch"
    end
  end

  describe "API-32 API-33 API-34 batch" do
    test "API-32: a partial batch is 207 with per-row results in input order", ctx do
      rows = [
        Map.put(event(), "ref", "a"),
        Map.put(event(%{"to" => ["missing-" <> TenantFixture.random()]}), "ref", "b")
      ]

      conn = F.request(:post, "/v1/events/batch", ctx.token, %{"events" => rows})
      body = F.body(conn, 207)

      assert body["summary"] == %{"total" => 2, "accepted" => 1, "rejected" => 1}
      assert [%{"index" => 0, "ref" => "a", "status" => "accepted"}, rejected] = body["results"]
      assert %{"index" => 1, "ref" => "b", "status" => "rejected"} = rejected
      assert rejected["error"]["code"] == "recipient_not_found"
      assert get_resp_header(conn, "relay-batch-max-events") == ["500"]
    end

    test "API-32: a batch without any accepted row is never 2xx", ctx do
      rows = [event(%{"to" => ["missing-" <> TenantFixture.random()]})]
      body = F.body(F.request(:post, "/v1/events/batch", ctx.token, %{"events" => rows}), 422)
      assert body["summary"]["accepted"] == 0
    end

    test "API-33: more than 500 events is 413 batch_too_large", ctx do
      rows = List.duplicate(event(), 501)
      body = problem(F.request(:post, "/v1/events/batch", ctx.token, %{"events" => rows}), 413)
      assert body["code"] == "batch_too_large"
      assert body["limit"] == 500
    end
  end

  describe "API-28 API-29 API-31 CloudEvents" do
    setup ctx do
      mapping = %{
        "type" => "com.shop.order.shipped",
        "workflow" => "order-shipped",
        "to_pointer" => "/customer",
        "data_fields" => ["/order"]
      }

      assert F.request(:post, "/v1/event_type_mappings", ctx.token, mapping).status == 201
      :ok
    end

    defp cloudevent(id) do
      %{
        "specversion" => "1.0",
        "id" => id,
        "source" => "https://shop.example.com/orders",
        "type" => "com.shop.order.shipped",
        "data" => %{
          "order" => "A-9",
          "secret" => "left out",
          "customer" => %{"id" => "ce-" <> TenantFixture.random(), "email" => "c@example.com"}
        }
      }
    end

    defp structured(token, event, headers \\ []) do
      conn =
        RelayTest.Api.conn(:post, "/v1/events", Jason.encode!(event), [
          {"content-type", "application/cloudevents+json"},
          {"authorization", "Bearer " <> token} | headers
        ])

      RelayTest.Api.call(conn, RelayWeb.Router)
    end

    test "API-28: a structured event is mapped and accepted without an Idempotency-Key", ctx do
      body = F.body(structured(ctx.token, cloudevent("order-1")), 202)
      assert body["workflow"]["key"] == "order-shipped"

      event = F.body(F.request(:get, "/v1/events/" <> body["id"], ctx.token), 200)
      assert event["source"] == "cloudevents"
      assert event["cloudevent"]["id"] == "order-1"
    end

    test "API-31: the derived key replays the same event", ctx do
      event = cloudevent("order-2")
      first = structured(ctx.token, event)
      again = structured(ctx.token, event)
      assert again.resp_body == first.resp_body
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
    end

    test "API-28: a binary mode event is mapped from its ce-* headers", ctx do
      event = cloudevent("order-3")

      conn =
        RelayTest.Api.conn(:post, "/v1/events", Jason.encode!(event["data"]), [
          {"content-type", "application/json"},
          {"authorization", "Bearer " <> ctx.token},
          {"ce-specversion", "1.0"},
          {"ce-id", event["id"]},
          {"ce-source", event["source"]},
          {"ce-type", event["type"]}
        ])

      assert F.body(RelayTest.Api.call(conn, RelayWeb.Router), 202)["recipient_count"] == 1
    end

    test "API-28: a CloudEvents batch answers with a batch result", ctx do
      raw = Jason.encode!([cloudevent("b-1"), cloudevent("b-2")])

      conn =
        RelayTest.Api.conn(:post, "/v1/events", raw, [
          {"content-type", "application/cloudevents-batch+json"},
          {"authorization", "Bearer " <> ctx.token}
        ])

      body = F.body(RelayTest.Api.call(conn, RelayWeb.Router), 202)
      assert body["summary"] == %{"total" => 2, "accepted" => 2, "rejected" => 0}
    end

    test "API-29: a type without a mapping is 422 event_type_not_mapped", ctx do
      event = Map.put(cloudevent("order-4"), "type", "com.shop.unknown")
      assert problem(structured(ctx.token, event), 422)["code"] == "event_type_not_mapped"
    end

    test "API-28: an extension attribute outside the contract is unknown_field", ctx do
      event = Map.put(cloudevent("order-5"), "partitionkey", "p")
      assert problem(structured(ctx.token, event), 422)["code"] == "unknown_field"
    end
  end

  describe "API-57 API-58 API-59 cancellation" do
    test "API-57: cancelling an event stops its pending deliveries and answers counts", ctx do
      body = accepted(ctx.token)
      cancelled = post(ctx.token, "/v1/events/#{body["id"]}/cancel", %{}, 200)

      assert cancelled["object"] == "cancellation"
      assert "cnl_" <> _ = cancelled["id"]
      assert cancelled["cancelled"] == 1
      assert cancelled["already_sent"] == 0

      assert get(ctx.token, "/v1/events/" <> body["id"])["status"] == "cancelled"
    end

    test "API-57: cancel by key matches every event with the key; no match is 200 with zeros",
         ctx do
      accepted(ctx.token, %{"cancellation_key" => "cart-7"})
      accepted(ctx.token, %{"cancellation_key" => "cart-7"})

      body = post(ctx.token, "/v1/events/cancel_by_key", %{"cancellation_key" => "cart-7"}, 200)
      assert body["cancelled"] == 2

      none = post(ctx.token, "/v1/events/cancel_by_key", %{"cancellation_key" => "none"}, 200)
      assert none["cancelled"] == 0
    end

    test "API-59: a delivery handed to a provider is already_sent, not cancelled", ctx do
      notification = first_notification(accepted(ctx.token))
      [%{"id" => delivery}] = deliveries(ctx.token, notification)
      {:ok, delivery_id} = Relay.ExternalId.decode(delivery, ["dlv"])

      attempt = %{id: Relay.Id.generate(), delivery_id: delivery_id}
      {:ok, {:opened, attempt_no}} = Relay.Delivery.open_attempt(ctx.scope, attempt)

      {:ok, :started} = Relay.Delivery.start_attempt(ctx.scope, delivery_id, attempt_no)

      cancelled = post(ctx.token, "/v1/notifications/#{notification}/cancel", %{}, 200)
      assert cancelled["cancelled"] == 0
      assert cancelled["already_sent"] == 1
    end

    test "API-57: an unknown event is 404", ctx do
      id = Relay.ExternalId.encode("evt", Relay.Id.generate())
      conn = F.request(:post, "/v1/events/#{id}/cancel", ctx.token, %{})
      assert code(conn, 404) == "event_not_found"
    end
  end

  describe "API-51 quota" do
    test "API-51: an exhausted quota is 429 quota_exhausted, never retryable", ctx do
      {:ok, _} =
        Relay.Ingest.in_event_scope(ctx.scope, fn _status ->
          Relay.Ingest.quota_policy_set(
            %{period: "month", limit_total: 1},
            TenantFixture.digest(),
            TenantFixture.actor()
          )
        end)

      accepted(ctx.token)
      conn = send_event(ctx.token, event())
      body = problem(conn, 429)

      assert body["code"] == "quota_exhausted"
      assert body["retryable"] == false
      assert body["quota"] == %{"bucket" => "general", "period" => "month"}
      assert get_resp_header(conn, "retry-after") == []
    end
  end

  describe "TN-40 kill switch at acceptance" do
    test "TN-40: a matching workflow kill switch pauses the delivery and queues no job", ctx do
      engaged =
        F.body(
          F.request(:post, "/v1/kill_switches", ctx.token, %{
            "scope_kind" => "workflow",
            "scope_ref" => "order-shipped",
            "reason" => "wrong template",
            "ttl" => "PT1H"
          }),
          201
        )

      assert engaged["scope_kind"] == "workflow"
      {:ok, records} = KillSwitch.list_active()
      Cache.put(Snapshot.new(1_000_000_000, records))

      try do
        notification = first_notification(accepted(ctx.token))
        [%{"id" => delivery, "reason" => "paused"}] = deliveries(ctx.token, notification)
        assert F.delivery_jobs(delivery) == []
      after
        Cache.forget()
      end
    end

    test "API-79: an API client may not engage a tenant kill switch or release one", ctx do
      body =
        problem(
          F.request(:post, "/v1/kill_switches", ctx.token, %{
            "scope_kind" => "tenant",
            "reason" => "stop",
            "ttl" => "PT1H"
          }),
          403
        )

      assert body["code"] == "auth_operator_session_required"

      engaged =
        post(
          ctx.token,
          "/v1/kill_switches",
          %{
            "scope_kind" => "workflow",
            "scope_ref" => "order-shipped",
            "reason" => "stop",
            "ttl" => "PT1H"
          },
          201
        )

      path = "/v1/kill_switches/#{engaged["id"]}/release"
      conn = F.request(:post, path, ctx.token, %{"reason" => "go"})
      assert code(conn, 403) == "auth_operator_session_required"
    end
  end

  describe "API-63 test plane" do
    test "API-63: the virtual clock is visible only to a test credential", ctx do
      test_token = F.token(ctx.tenant.test)
      clock = get(test_token, "/v1/virtual_clock")
      assert clock["object"] == "virtual_clock"

      advanced = post(test_token, "/v1/virtual_clock/advance", %{"by" => "PT1H"}, 200)
      assert advanced["offset_ms"] == clock["offset_ms"] + 3_600_000

      assert problem(F.request(:get, "/v1/virtual_clock", ctx.token), 403)["code"] ==
               "auth_environment_mismatch"
    end
  end

  describe "API-56 queries" do
    test "API-56: notifications list newest first with a signed next cursor", ctx do
      for _ <- 1..3, do: accepted(ctx.token)

      page = get(ctx.token, "/v1/notifications?limit=2")
      assert length(page["data"]) == 2
      assert page["has_more"] == true

      rest = get(ctx.token, "/v1/notifications?limit=2&starting_after=" <> page["next_cursor"])
      assert length(rest["data"]) == 1
    end

    test "DS-15: a delivery's history carries its ledger", ctx do
      notification = first_notification(accepted(ctx.token))
      [%{"id" => delivery}] = deliveries(ctx.token, notification)

      history = get(ctx.token, "/v1/deliveries/#{delivery}/history")
      assert [%{"type" => "delivery.queued"}] = history["events"]
    end

    test "TN-15: another tenant's event is 404", ctx do
      body = accepted(ctx.token)
      other = F.token(TenantFixture.tenant!().live)
      assert code(F.request(:get, "/v1/events/" <> body["id"], other), 404) == "event_not_found"
    end
  end
end
