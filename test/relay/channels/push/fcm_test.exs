defmodule Relay.Channels.Push.FcmTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Fcm

  defp base(extra) do
    defaults = %{
      token: "fcm-token",
      fcm_priority: :high,
      ttl: "3600s",
      collapse_key: "relay.security",
      topic: "subject-key",
      channel_id: "relay.security.time-sensitive",
      notification: %{title: "Sign-in", body: "New sign-in from Ankara"},
      data: %{"kind" => "security"}
    }

    Map.merge(defaults, extra)
  end

  describe "CH-24 HTTP v1 messages" do
    test "CH-24: the android block carries the policy values and the channel" do
      assert {:ok, message, []} = Fcm.message(base(%{}))

      assert message == %{
               "token" => "fcm-token",
               "data" => %{"kind" => "security", "relay_topic" => "subject-key"},
               "android" => %{
                 "priority" => "HIGH",
                 "ttl" => "3600s",
                 "collapse_key" => "relay.security",
                 "notification" => %{
                   "title" => "Sign-in",
                   "body" => "New sign-in from Ankara",
                   "channel_id" => "relay.security.time-sensitive"
                 }
               }
             }
    end

    test "CH-24: the request goes to the v1 endpoint with the bearer token" do
      {:ok, message, []} = Fcm.message(base(%{}))
      request = Fcm.request("relay-test", message, Relay.Redacted.wrap("ya29.x"))

      assert request.url == "https://fcm.googleapis.com/v1/projects/relay-test/messages:send"
      assert {"authorization", "Bearer ya29.x"} in request.headers
      assert Jason.decode!(request.body) == %{"message" => message}
    end

    test "CH-30: the channel id is the category and the level" do
      assert Fcm.android_channel("orders", :passive) == {:ok, "relay.orders.passive"}
      assert {:ok, "relay.orders.time-sensitive"} = Fcm.android_channel("orders", :time_sensitive)
      assert {:error, %{code: :fcm_channel_invalid}} = Fcm.android_channel("Bad Name", :active)
    end

    test "CH-21: a raw android override cannot change priority or channel" do
      override = %{"priority" => "NORMAL", "notification" => %{"channel_id" => "x", "tag" => "t"}}
      assert {:ok, message, ignored} = Fcm.message(base(%{override_android: override}))

      assert ignored == ["android.priority", "android.notification.channel_id"]
      assert message["android"]["priority"] == "HIGH"
      assert message["android"]["notification"]["channel_id"] == "relay.security.time-sensitive"
      assert message["android"]["notification"]["tag"] == "t"
    end
  end

  describe "CH-33 data messages" do
    test "CH-33: a content-free message is data only with the opaque id and neutral text" do
      content_free = %{id: "n-1", locale: "en", lock_screen_body: nil}
      extra = %{content_free: content_free, override_android: %{"notification" => %{}}}
      assert {:ok, message, ["android"]} = Fcm.message(base(extra))

      refute Map.has_key?(message["android"], "notification")

      assert message["data"] == %{
               "relay_id" => "n-1",
               "relay_neutral_title" => "New notification",
               "relay_neutral_body" => "You have a new notification.",
               "relay_topic" => "subject-key"
             }
    end

    test "CH-26: a system message is data only at normal priority" do
      extra = %{data_only: true, fcm_priority: :normal}
      assert {:ok, message, []} = Fcm.message(base(extra))
      refute Map.has_key?(message["android"], "notification")
      assert message["android"]["priority"] == "NORMAL"
    end

    test "INV-60: codes, links and oversized payloads are refused" do
      code = %{notification: %{title: "Kod", body: "Doğrulama kodunuz 123456"}}
      assert {:error, %{code: :push_content_forbidden}} = Fcm.message(base(code))

      big = %{data: %{"x" => String.duplicate("a", 4001)}}
      assert {:error, %{code: :push_payload_too_large}} = Fcm.message(base(big))

      assert {:error, %{code: :fcm_request_invalid}} = Fcm.message(base(%{data: %{"n" => 1}}))
      assert {:error, %{code: :fcm_request_invalid}} = Fcm.message(base(%{token: ""}))
    end
  end
end
