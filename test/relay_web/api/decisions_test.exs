defmodule RelayWeb.Api.DecisionsTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{scope: tenant.live, token: token, subscriber: "user-" <> TenantFixture.random()}
  end

  defp accepted(ctx) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => ctx.subscriber, "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    answer = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = answer["notifications"]
    notification
  end

  defp get(ctx, path), do: F.body(F.request(:get, path, ctx.token), 200)

  describe "DS-28 X-12 decision chain" do
    test "DS-28, X-12: a cancelled delivery shows its channel, result and the rule's sentence",
         ctx do
      notification = accepted(ctx)
      F.body(F.request(:post, "/v1/notifications/#{notification}/cancel", ctx.token, %{}), 200)

      page = get(ctx, "/v1/subscribers/#{ctx.subscriber}/decisions")
      assert [chain] = page["data"]
      assert chain["object"] == "notification_decision"
      assert chain["notification_id"] == notification
      assert chain["workflow"]["key"] == "order-shipped"

      assert [delivery] = chain["deliveries"]
      assert delivery["channel"] == "email"
      assert delivery["status"] == "cancelled"
      assert delivery["gates"] == "passed"
      assert is_binary(delivery["rule_id"])

      assert [step] = delivery["decisions"]
      assert step["rule_id"] == delivery["rule_id"]
      assert step["outcome"] == "cancel"
      assert {:ok, sentence} = Relay.Rules.describe(step["rule_id"], "en")
      assert step["description"]["en"] == sentence
      assert step["detail"] == %{}
    end

    test "DS-28: a queued delivery passed the gates and has no decision", ctx do
      accepted(ctx)
      [chain] = get(ctx, "/v1/subscribers/#{ctx.subscriber}/decisions")["data"]
      assert [delivery] = chain["deliveries"]
      assert %{"status" => "queued", "gates" => "passed", "decisions" => []} = delivery
    end

    test "DS-28: the window and an unknown subscriber are honoured", ctx do
      accepted(ctx)
      path = "/v1/subscribers/#{ctx.subscriber}/decisions?created_before=2020-01-01T00:00:00Z"
      assert get(ctx, path)["data"] == []

      conn = F.request(:get, "/v1/subscribers/nobody-here/decisions", ctx.token)
      assert F.body(conn, 404)["code"] == "subscriber_not_found"

      path = "/v1/subscribers/#{ctx.subscriber}/decisions?created_after=x"
      assert F.body(F.request(:get, path, ctx.token), 422)["code"] == "validation_failed"
    end
  end

  describe "DS-16 history" do
    test "DS-16: each ledger event shows its effect on the projection and its rule", ctx do
      notification = accepted(ctx)
      F.body(F.request(:post, "/v1/notifications/#{notification}/cancel", ctx.token, %{}), 200)

      [%{"id" => delivery}] = get(ctx, "/v1/notifications/#{notification}/deliveries")["data"]

      events = get(ctx, "/v1/deliveries/#{delivery}/history")["events"]
      assert Enum.map(events, & &1["type"]) == ["delivery.queued", "delivery.cancelled"]
      assert Enum.all?(events, &(&1["outcome"] == "applied"))
      assert List.last(events)["rule_id"] != nil
      assert List.last(events)["reason"] != nil
    end
  end
end
