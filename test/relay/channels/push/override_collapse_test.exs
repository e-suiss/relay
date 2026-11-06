defmodule Relay.Channels.Push.OverrideCollapseTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Collapse
  alias Relay.Channels.Push.Override

  describe "CH-21 policy field protection" do
    test "CH-21: a raw apns.payload cannot change the interruption level" do
      policy = %{"aps" => %{"interruption-level" => "active", "alert" => %{"body" => "Hi"}}}

      aps = %{"interruption-level": "critical", sound: "ping.caf"}
      override = %{:aps => aps, "deep" => %{"x" => 1}}

      assert {payload, ["apns.payload.aps.interruption-level"]} =
               Override.apns_payload(policy, override)

      assert payload["aps"] == %{
               "interruption-level" => "active",
               "alert" => %{"body" => "Hi"},
               "sound" => "ping.caf"
             }

      assert payload["deep"] == %{"x" => 1}
    end

    test "CH-21: a policy field the policy leaves out stays out" do
      policy = %{"aps" => %{"content-available" => 1}}
      override = %{"aps" => %{"interruption-level" => "time-sensitive"}}

      assert {%{"aps" => %{"content-available" => 1}}, ["apns.payload.aps.interruption-level"]} =
               Override.apns_payload(policy, override)
    end

    test "CH-21: raw headers cannot change priority or push type, whatever their case" do
      policy = %{"apns-priority" => "5", "apns-push-type" => "alert", "apns-topic" => "a.b"}
      override = %{"APNs-Priority" => "10", "apns-push-type" => "voip", "apns-topic" => "a.b"}

      assert {headers, ["apns.headers.apns-priority", "apns.headers.apns-push-type"]} =
               Override.apns_headers(policy, override)

      assert headers == policy
    end

    test "CH-21: a raw FCM android block cannot change priority or channel" do
      policy = %{"priority" => "NORMAL", "notification" => %{"channel_id" => "relay.news"}}

      override = %{
        "priority" => "HIGH",
        "notification" => %{"channel_id" => "alarm", "color" => "#ff0000"},
        "direct_boot_ok" => true
      }

      assert {android, ["android.priority", "android.notification.channel_id"]} =
               Override.android(policy, override)

      assert android == %{
               "priority" => "NORMAL",
               "notification" => %{"channel_id" => "relay.news", "color" => "#ff0000"},
               "direct_boot_ok" => true
             }
    end

    test "CH-21: an override equal to the policy is not reported and none changes nothing" do
      policy = %{"priority" => "HIGH"}
      assert Override.android(policy, %{"priority" => "HIGH"}) == {policy, []}
      assert Override.android(policy, nil) == {policy, []}
      assert Override.apns_headers(policy, nil) == {policy, []}
    end

    test "CH-21: raw FCM apns and webpush blocks carry no APNs policy field or Urgency" do
      apns = %{
        "headers" => %{"APNs-Priority" => "10", "apns-collapse-id" => "c"},
        "payload" => %{"aps" => %{"interruption-level" => "critical", "badge" => 1}}
      }

      assert {block, ignored} = Override.fcm_apns(apns)
      assert ignored == [
               "fcm.apns.headers.apns-priority",
               "fcm.apns.payload.aps.interruption-level"
             ]

      assert block == %{
               "headers" => %{"apns-collapse-id" => "c"},
               "payload" => %{"aps" => %{"badge" => 1}}
             }

      webpush = %{"headers" => %{"Urgency" => "high", "TTL" => "60"}, "fcm_options" => %{}}

      assert {block, ["fcm.webpush.headers.urgency"]} = Override.fcm_webpush(webpush)
      assert block == %{"headers" => %{"ttl" => "60"}, "fcm_options" => %{}}

      assert Override.fcm_apns(nil) == {nil, []}
      assert Override.fcm_webpush(nil) == {nil, []}
    end

    test "CH-21, CH-27: a raw HMS android block cannot change urgency, importance or category" do
      policy = %{"urgency" => "NORMAL", "notification" => %{"importance" => "LOW"}}

      override = %{
        "urgency" => "HIGH",
        "category" => "IM",
        "notification" => %{"importance" => "NORMAL", "color" => "#00ff00"}
      }

      assert {android, ignored} = Override.hms_android(policy, override)

      assert ignored == [
               "hms.android.urgency",
               "hms.android.notification.importance",
               "hms.android.category"
             ]

      assert android == %{
               "urgency" => "NORMAL",
               "notification" => %{"importance" => "LOW", "color" => "#00ff00"}
             }
    end

    test "CH-21, CH-23: a raw Web Push payload keeps the opaque identifier and the topic" do
      policy = %{"relay_id" => "d1", "title" => "Hi"}
      override = %{"relay_id" => "other", "relay_topic" => "t", "badge" => "/b.png"}

      assert {payload, ignored} = Override.web_push_payload(policy, override)
      assert payload == %{"relay_id" => "d1", "title" => "Hi", "badge" => "/b.png"}
      assert ignored == ["web_push.payload.relay_id", "web_push.payload.relay_topic"]
    end

    test "API-23, CH-60: a raw WhatsApp block keeps the addressing, type and template" do
      policy = %{
        "to" => "+905551112233",
        "biz_opaque_callback_data" => "c1",
        "type" => "template",
        "template" => %{"name" => "t", "language" => %{"code" => "tr"}}
      }

      override = %{
        "to" => "+15550000000",
        "type" => "text",
        "template" => %{"name" => "other", "components" => []},
        "context" => %{"message_id" => "wamid.1"}
      }

      assert {body, ["whatsapp.to", "whatsapp.type", "whatsapp.template.name"]} =
               Override.whatsapp(policy, override)

      assert body == %{
               "to" => "+905551112233",
               "biz_opaque_callback_data" => "c1",
               "type" => "template",
               "template" => %{
                 "name" => "t",
                 "language" => %{"code" => "tr"},
                 "components" => []
               },
               "context" => %{"message_id" => "wamid.1"}
             }
    end
  end

  describe "CH-23 collapse keys" do
    @subject %{
      tenant_id: <<1::128>>,
      subject_type: "order",
      subject_id: "o-42",
      message_class: :transactional
    }

    test "CH-23: the same subject collapses, different subjects never mix" do
      same = %{@subject | message_class: "transactional"}
      assert Collapse.topic(@subject) == Collapse.topic(same)

      changes = %{
        tenant_id: <<2::128>>,
        subject_type: "invoice",
        subject_id: "o-43",
        message_class: :marketing
      }

      for {key, value} <- changes do
        refute Collapse.topic(@subject) == Collapse.topic(Map.put(@subject, key, value))
      end

      refute Collapse.topic(%{@subject | subject_type: "a", subject_id: "bc"}) ==
               Collapse.topic(%{@subject | subject_type: "ab", subject_id: "c"})
    end

    test "CH-23: each platform gets a key within its limit" do
      keys = Collapse.keys(@subject, "relay.transactional")

      assert byte_size(keys.apns) <= Collapse.apns_limit()
      assert keys.apns == Collapse.apns(@subject)
      assert String.length(keys.web_push) == 32
      assert keys.web_push =~ ~r/\A[A-Za-z0-9_-]{32}\z/
      assert keys.web_push == Collapse.web_push(@subject)
      assert String.starts_with?(keys.topic, keys.web_push)
      assert keys.fcm == "relay.transactional"
    end
  end
end
