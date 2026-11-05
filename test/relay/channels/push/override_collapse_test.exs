defmodule Relay.Channels.Push.OverrideCollapseTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Collapse
  alias Relay.Channels.Push.Override

  describe "CH-21 policy field protection" do
    test "CH-21: a raw apns.payload cannot change the interruption level" do
      policy = %{"aps" => %{"interruption-level" => "active", "alert" => %{"body" => "Hi"}}}

      override = %{
        aps: %{"interruption-level": "critical", sound: "ping.caf"},
        "deep" => %{"x" => 1}
      }

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
