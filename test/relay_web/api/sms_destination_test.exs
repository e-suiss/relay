defmodule RelayWeb.Api.SmsDestinationTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.DestinationGuard
  alias Relay.DestinationGuard.Destination
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @policy "/v1/sms_destination_policy"
  @stops "/v1/sms_destination_stops"
  @home %{tr: "+905551234567", eu: "+4915112345678", us: "+12125550100"}
  @abroad "+447911123456"
  @not_found "sms_destination_stop_not_found"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{scope: scope, token: F.token(scope), region: tenant.attrs.region}
  end

  defp get(token, path), do: F.body(F.request(:get, path, token), 200)

  defp put_policy(token, countries),
    do: F.request(:put, @policy, token, %{"allowed_countries" => countries})

  defp stop!(scope, value \\ "+905551234") do
    {:ok, {:opened, id}} =
      DestinationGuard.stop(scope, %{
        kind: :prefix,
        value: value,
        country: "TR",
        rule_id: "destination.pumping_prefix",
        detail: %{"current" => 60, "baseline" => 60, "threshold" => 60, "window" => "PT10M"}
      })

    Relay.ExternalId.encode("sds", id)
  end

  defp lift(token, id, reason \\ "the range is ours"),
    do: F.request(:post, "#{@stops}/#{id}/lift", token, %{"reason" => reason})

  defp otp_workflow!(ctx, key) do
    step = %{
      "type" => "channel",
      "key" => "code",
      "route" => %{"single" => ["sms", "voice"]},
      "template" => "order-shipped"
    }

    definition = Map.put(F.definition(message_class: "security"), "steps", [step])
    :ok = F.category_of!(ctx.token, definition)
    :ok = F.template!(ctx.scope, "order-shipped", definition["category"])
    body = %{"key" => key, "definition" => definition}
    created = F.request(:post, "/v1/workflows", ctx.token, body)
    assert created.status == 201, created.resp_body
    F.publish!(ctx.scope, ctx.token, key)
  end

  defp otp(phone, extra \\ %{}) do
    expires = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 600))

    Map.merge(
      %{
        "workflow" => "login-code",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "phone" => phone}],
        "data" => %{"order" => "A-1"},
        "security_subtype" => "otp_oob",
        "expires_at" => expires
      },
      extra
    )
  end

  defp send_event(token, body, headers \\ []),
    do: F.request(:post, "/v1/events", token, body, headers)

  defp notification(accepted) do
    [%{"notification_id" => notification}] = accepted["notifications"]
    notification
  end

  defp channels(token, accepted) do
    path = "/v1/notifications/#{notification(accepted)}/deliveries"
    Enum.map(get(token, path)["data"], & &1["channel"])
  end

  defp frozen(scope, accepted) do
    {:ok, id} = Relay.ExternalId.decode(notification(accepted), ["ntf"])
    {:ok, run} = Relay.Workflow.run(scope, id)
    run["plan"]["otp"]
  end

  describe "CH-54 country allow-list on the API" do
    test "CH-54: the policy shows the region's countries and the countries the tenant added",
         ctx do
      shown = get(ctx.token, @policy)

      assert shown["object"] == "sms_destination_policy"
      assert shown["region_countries"] == Destination.region_countries(ctx.region)
      assert shown["allowed_countries"] == []

      replaced = F.body(put_policy(ctx.token, ["GB", "AZ"]), 200)
      assert replaced["allowed_countries"] == ["AZ", "GB"]
      assert get(ctx.token, @policy)["allowed_countries"] == ["AZ", "GB"]
      assert {:ok, %{allowed_countries: ["AZ", "GB"]}} = DestinationGuard.allow_list(ctx.scope)
      assert DestinationGuard.open?(ctx.scope, "GB")

      assert F.body(put_policy(ctx.token, []), 200)["allowed_countries"] == []
      refute DestinationGuard.open?(ctx.scope, "GB")
    end

    test "CH-54: a value that is not a country code and a repeated country are field errors",
         ctx do
      body = F.body(put_policy(ctx.token, ["GB", "gb", "GB"]), 422)

      assert body["code"] == "validation_failed"

      assert Enum.map(body["errors"], &{&1["pointer"], &1["code"]}) == [
               {"/allowed_countries/1", "invalid_format"},
               {"/allowed_countries/2", "conflict"}
             ]

      assert get(ctx.token, @policy)["allowed_countries"] == []
    end
  end

  describe "CH-54 stops on the API" do
    test "CH-54: stops are listed with their detection and filtered by state", ctx do
      id = stop!(ctx.scope)

      assert [stop] = get(ctx.token, @stops)["data"]

      assert %{
               "object" => "sms_destination_stop",
               "id" => ^id,
               "kind" => "prefix",
               "value" => "+905551234",
               "country" => "TR",
               "rule_id" => "destination.pumping_prefix",
               "state" => "active",
               "lifted_at" => nil
             } = stop

      assert stop["detail"]["threshold"] == 60
      assert [%{"id" => ^id}] = get(ctx.token, @stops <> "?state=active")["data"]
      assert get(ctx.token, @stops <> "?state=lifted")["data"] == []
      assert F.body(F.request(:get, @stops <> "?state=gone", ctx.token), 422)["code"]
    end

    test "CH-54: lifting a stop is an explicit action with a reason", ctx do
      id = stop!(ctx.scope)

      lifted = F.body(lift(ctx.token, id), 200)
      assert %{"id" => ^id, "state" => "lifted", "lift_reason" => "the range is ours"} = lifted
      assert is_binary(lifted["lifted_by"]) and is_binary(lifted["lifted_at"])

      assert F.body(lift(ctx.token, id, "again"), 200)["lift_reason"] == "the range is ours"
      released = OutboxEvents.data(ctx.scope, "sms_destination.released")
      assert [%{"value" => "+905551234"}] = released
      assert [%{"id" => ^id}] = get(ctx.token, @stops <> "?state=lifted")["data"]

      unknown = Relay.ExternalId.encode("sds", Relay.Id.generate())
      assert F.body(lift(ctx.token, unknown), 404)["code"] == @not_found
      assert F.body(lift(ctx.token, "sds_nothing"), 404)["code"] == @not_found
    end

    test "CH-54: a stop is only visible in its own tenant and environment", ctx do
      id = stop!(ctx.scope)
      other = TenantFixture.tenant!()

      assert get(F.token(other.test), @stops)["data"] == []
      assert F.body(lift(F.token(other.test), id), 404)["code"] == @not_found
      assert [%{"state" => "active"}] = get(ctx.token, @stops)["data"]
    end
  end

  describe "E-34 PC-52 PC-53 OTP division of labour on the API" do
    setup ctx do
      otp_workflow!(ctx, "login-code")
      :ok
    end

    test "E-34, INV-22: resending a code is a new request with a new idempotency key", ctx do
      body = otp(Map.fetch!(@home, ctx.region))
      key = [{"idempotency-key", "otp-" <> TenantFixture.random()}]

      first = F.body(send_event(ctx.token, body, key), 202)
      replay = send_event(ctx.token, body, key)

      assert F.body(replay, 202)["id"] == first["id"]
      assert get_resp_header(replay, "idempotency-replayed") == ["true"]

      resent = F.body(send_event(ctx.token, body), 202)
      refute resent["id"] == first["id"]
      refute notification(resent) == notification(first)
    end

    test "PC-53: the chain's inputs are frozen with the run when the notification is created",
         ctx do
      signals = %{"security_signals" => %{"sim_changed" => true}}
      accepted = F.body(send_event(ctx.token, otp(@abroad, signals)), 202)

      assert %{
               "permitted" => ["sms", "voice"],
               "country" => "GB",
               "closed" => ["sms"],
               "whatsapp_reachable" => false,
               "sim_changed" => true,
               "mobile_app_active" => nil
             } = frozen = frozen(ctx.scope, accepted)

      assert is_list(frozen["unhealthy"])
      refute Jason.encode!(frozen) =~ "447911123456"
    end

    test "PC-53, CH-54: SMS closed for the recipient's country gives way to voice", ctx do
      abroad = F.body(send_event(ctx.token, otp(@abroad)), 202)
      assert channels(ctx.token, abroad) == ["voice"]

      home = F.body(send_event(ctx.token, otp(Map.fetch!(@home, ctx.region))), 202)
      assert channels(ctx.token, home) == ["sms"]
    end

    test "PC-52: the chain never leaves the sender's permitted channels", ctx do
      narrowed = otp(@abroad, %{"channels" => ["sms"]})
      accepted = F.body(send_event(ctx.token, narrowed), 202)

      assert frozen(ctx.scope, accepted)["permitted"] == ["sms"]
      assert channels(ctx.token, accepted) -- ["sms"] == []
    end

    test "E-33, API-24: the sender's signals are accepted only on an otp_oob request", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")

      plain = %{
        "workflow" => "order-shipped",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"},
        "security_signals" => %{"mobile_app_active" => true}
      }

      body = F.body(send_event(ctx.token, plain), 422)
      assert "/security_signals" in Enum.map(body["errors"], & &1["pointer"])

      unknown = otp(@abroad, %{"security_signals" => %{"device_rooted" => true}})
      assert F.body(send_event(ctx.token, unknown), 422)["code"] == "unknown_field"

      active = otp(@abroad, %{"security_signals" => %{"mobile_app_active" => true}})
      accepted = F.body(send_event(ctx.token, active), 202)
      assert frozen(ctx.scope, accepted)["mobile_app_active"] == true
    end
  end
end
