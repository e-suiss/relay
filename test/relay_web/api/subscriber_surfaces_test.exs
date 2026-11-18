defmodule RelayWeb.Api.SubscriberSurfacesTest do
  use Relay.DataCase, async: false

  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.RealtimeFixture
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    token = F.token(scope)
    app = FakeAccess.client!(scope, ["read"])
    ctx = %{scope: scope, access_tenant: tenant.attrs.access_tenant_id, app: app, token: token}
    sub = RealtimeFixture.subject()
    {subscriber_token, id} = RealtimeFixture.token!(ctx, sub)
    Map.merge(ctx, %{sub: sub, subscriber_token: subscriber_token, id: id})
  end

  defp deliveries(ctx, workflow) do
    body = %{"workflow" => workflow, "to" => [ctx.sub], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    F.body(F.request(:get, path, ctx.token), 200)["data"]
  end

  defp run!(ctx, %{"id" => external}) do
    {:ok, id} = Relay.ExternalId.decode(external, ["dlv"])
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", Relay.Id.to_string(id))
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    {id, args}
  end

  describe "X-44 consents on the subscriber surface" do
    test "X-44: the subscriber reads its consent copy read-only", ctx do
      now = DateTime.utc_now()

      {:ok, _recorded} =
        Relay.Preferences.record_consent(ctx.scope, %{
          recipient_id: ctx.id,
          brand_subtenant_id: nil,
          channel: "email",
          status: "revoked",
          consent_kind: "explicit_opt_in",
          recipient_type: "individual",
          source: "test",
          sequence: DateTime.to_unix(now, :microsecond),
          occurred_at: now,
          text_version_digest: nil,
          evidence: nil,
          iys_transaction_ref: nil,
          source_event_ref: "test:consent"
        })

      body = F.body(F.request(:get, "/v1/subscriber/consents", ctx.subscriber_token), 200)
      assert [%{"object" => "consent", "channel" => "email"} = consent] = body["data"]
      assert consent["status"] == "revoked"
    end
  end

  describe "C-24 AG-35 inbox item fields" do
    test "C-24 AG-34: an inbox item names its sender type and carries no waitpoint", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["in_app"])
      [delivery] = deliveries(ctx, "order-shipped")
      {id, args} = run!(ctx, delivery)
      :ok = Relay.Channels.Live.deliver(ctx.scope, id, args)

      body = F.body(F.request(:get, "/v1/subscriber/inbox/items", ctx.subscriber_token), 200)
      assert [item] = body["data"]
      assert item["sender_type"] in ["human", "system", "agent"]
      assert item["approval"] == false
      assert item["waitpoint"] == nil
    end
  end

  describe "CH-33 content-free push content" do
    test "CH-33: the app fetches the content of its own push delivery and nobody else's", ctx do
      device = %{
        "platform" => "fcm",
        "token" => "sim:delivered",
        "app" => "com.example.app",
        "permission" => "granted"
      }

      F.body(F.request(:post, "/v1/subscriber/devices", ctx.subscriber_token, device), 201)
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["push"])
      [delivery] = deliveries(ctx, "order-shipped")
      run!(ctx, delivery)

      path = "/v1/subscriber/push_content/" <> delivery["id"]
      body = F.body(F.request(:get, path, ctx.subscriber_token), 200)

      assert body["object"] == "push_content"
      assert body["delivery_id"] == delivery["id"]
      assert body["channel"] == "push"
      assert is_binary(body["content"]["title"])

      {other_token, _other} = RealtimeFixture.token!(ctx, RealtimeFixture.subject())
      assert F.body(F.request(:get, path, other_token), 404)["code"] == "delivery_not_found"
    end
  end
end
