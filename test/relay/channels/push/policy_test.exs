defmodule Relay.Channels.Push.PolicyTest do
  use ExUnit.Case, async: true

  alias RelayTest.PushFixture

  describe "CH-19 CH-65 push policy" do
    test "CH-19: the platform values come from the class row and a priority above the ceiling is clamped" do
      policy = PushFixture.policy(%{message_class: "marketing", priority: "high"})

      assert policy.mapping.priority == :normal
      assert policy.mapping.apns_priority == 5
      assert :priority_clamped in policy.reasons
      assert policy.level == :passive
    end

    test "CH-65: the sender's level is lowered to the class ceiling and recorded" do
      facts = %{message_class: "transactional", interruption: "time-sensitive"}
      policy = PushFixture.policy(facts)

      assert policy.level == :active
      assert policy.reasons == [:interruption_clamped]
    end

    test "CH-66: critical without the opening, the declaration and a Grant is delivered at the ceiling" do
      policy = PushFixture.policy(%{message_class: "security", interruption: "critical"})

      assert policy.level == :time_sensitive
      assert :critical_not_granted in policy.reasons

      critical = %{enabled: true, declared: true, grant: :permit}
      facts = %{message_class: "security", interruption: "critical"}
      lowered = PushFixture.policy(Map.put(facts, :critical, critical))

      assert lowered.level == :time_sensitive
      assert lowered.reasons == [:interruption_platform_lowered]

      entitled = Map.put(critical, :entitled, true)
      granted = PushFixture.policy(Map.put(facts, :critical, entitled))

      assert granted.level == :critical
      assert granted.reasons == []
    end

    test "CH-23: a notification without a subject collapses with nothing" do
      assert PushFixture.policy().collapse == nil

      keyed = PushFixture.policy(%{subject_type: "order", subject_id: "42"})
      assert byte_size(keyed.collapse.apns) <= 64
      assert byte_size(keyed.collapse.web_push) == 32
      assert keyed.collapse.fcm == "relay.transactional"
    end

    test "CH-33, CH-67: sensitive, security and the Türkiye region go content-free" do
      refute PushFixture.policy().content_free
      assert PushFixture.policy(%{sensitivity: "sensitive"}).content_free
      assert PushFixture.policy(%{sensitive: true}).content_free
      assert PushFixture.policy(%{message_class: "security"}).content_free
      assert PushFixture.policy(%{region: "tr"}).content_free
    end
  end
end
