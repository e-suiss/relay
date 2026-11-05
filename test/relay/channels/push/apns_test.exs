defmodule Relay.Channels.Push.ApnsTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Apns

  @token String.duplicate("ab", 32)
  @id <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

  defp base(extra) do
    defaults = %{
      push_type: :alert,
      bundle_id: "com.example.app",
      apns_id: @id,
      apns_priority: 10,
      device_token: @token,
      interruption_level: :time_sensitive,
      aps: %{alert: %{title: "Hi", body: "Your parcel is on its way"}}
    }

    Map.merge(defaults, extra)
  end

  defp build(extra) do
    {:ok, request} = Apns.request(base(extra))
    {request, Jason.decode!(request.body), Map.new(request.headers)}
  end

  describe "CH-24 requests" do
    test "CH-24: an alert carries the policy headers and level" do
      {request, payload, headers} = build(%{collapse_id: "topic-key", expiration: 1_793_840_400})

      assert request.path == "/3/device/" <> @token

      assert headers == %{
               "apns-push-type" => "alert",
               "apns-topic" => "com.example.app",
               "apns-priority" => "10",
               "apns-id" => "01020304-0506-0708-090a-0b0c0d0e0f10",
               "apns-expiration" => "1793840400",
               "apns-collapse-id" => "topic-key"
             }

      assert payload["aps"]["interruption-level"] == "time-sensitive"
      assert payload["aps"]["alert"]["body"] == "Your parcel is on its way"
      assert request.override_ignored == []
    end

    test "CH-24: every push type has its topic" do
      for type <- Apns.push_types() do
        assert String.starts_with?(Apns.topic(type, "com.example.app"), "com.example.app")
      end

      assert Apns.topic(:voip, "a.b") == "a.b.voip"
      assert Apns.topic(:liveactivity, "a.b") == "a.b.push-type.liveactivity"
      assert Apns.topic(:complication, "a.b") == "a.b.complication"
      assert Apns.topic(:fileprovider, "a.b") == "a.b.pushkit.fileprovider"
      assert Apns.topic(:location, "a.b") == "a.b.location-query"
      assert Apns.topic(:pushtotalk, "a.b") == "a.b.voip-ptt"
    end

    test "CH-19: a background push is silent at priority 5 without a level" do
      {_request, payload, headers} = build(%{push_type: :background})

      assert headers["apns-push-type"] == "background"
      assert headers["apns-priority"] == "5"
      assert payload["aps"] == %{"content-available" => 1}
    end

    test "CH-24: push-to-start and broadcast Live Activities" do
      start = %{
        event: :start,
        timestamp: 1_793_836_800,
        content_state: %{progress: 1},
        attributes_type: "DeliveryAttributes",
        attributes: %{order: "o-42"},
        input_push_token: true
      }

      {request, payload, headers} = build(%{push_type: :liveactivity, live_activity: start})
      assert request.path == "/3/device/" <> @token
      assert headers["apns-topic"] == "com.example.app.push-type.liveactivity"
      assert payload["aps"]["event"] == "start"
      assert payload["aps"]["attributes-type"] == "DeliveryAttributes"
      assert payload["aps"]["content-state"] == %{"progress" => 1}
      assert payload["aps"]["input-push-token"] == 1

      update = %{event: :update, timestamp: 1_793_836_900, content_state: %{progress: 2}}
      broadcast = %{push_type: :liveactivity, live_activity: update, channel_id: "ch-1"}
      {request, payload, headers} = build(Map.merge(broadcast, %{device_token: nil}))
      assert request.path == "/4/broadcasts/apps/com.example.app"
      assert headers["apns-channel-id"] == "ch-1"
      assert payload["aps"]["event"] == "update"

      assert {:error, %{code: :apns_request_invalid}} =
               Apns.request(base(%{push_type: :liveactivity, live_activity: %{event: :start}}))

      assert {:error, %{code: :apns_request_invalid}} = Apns.request(base(%{channel_id: "ch-1"}))
    end

    test "CH-21: raw overrides cannot change the policy fields" do
      overrides = %{
        override_payload: %{"aps" => %{"interruption-level" => "critical", "badge" => 3}},
        override_headers: %{"apns-priority" => "5", "apns-push-type" => "voip"}
      }

      {request, payload, headers} = build(overrides)

      assert payload["aps"]["interruption-level"] == "time-sensitive"
      assert payload["aps"]["badge"] == 3
      assert headers["apns-priority"] == "10"
      assert headers["apns-push-type"] == "alert"

      assert request.override_ignored == [
               "apns.payload.aps.interruption-level",
               "apns.headers.apns-priority",
               "apns.headers.apns-push-type"
             ]
    end
  end

  describe "CH-33 content-free and INV-60" do
    test "CH-33: a content-free push carries neutral text and the opaque id only" do
      content_free = %{id: "n-123", locale: "tr", lock_screen_body: nil}

      extra = %{
        content_free: content_free,
        data: %{order: "o-42"},
        override_payload: %{"aps" => %{"alert" => %{"body" => "full content"}}}
      }

      {request, payload, _headers} = build(extra)

      assert payload == %{
               "aps" => %{
                 "alert" => %{"title" => "Yeni bildirim", "body" => "Yeni bir bildiriminiz var."},
                 "mutable-content" => 1,
                 "interruption-level" => "time-sensitive"
               },
               "relay" => %{"id" => "n-123"}
             }

      assert request.override_ignored == ["apns.payload"]
    end

    test "INV-60: a payload with a one-time code is refused" do
      aps = %{alert: %{body: "Doğrulama kodunuz 123456"}}

      assert {:error, %{code: :push_content_forbidden}} = Apns.request(base(%{aps: aps}))

      override = %{"link" => "https://x.example/login?token=abc"}

      assert {:error, %{code: :push_content_forbidden}} =
               Apns.request(base(%{override_payload: override}))
    end

    test "CH-24: the size limit is 4096 bytes, 5120 for VoIP, and nothing is cut" do
      big = %{alert: %{body: String.duplicate("a", 4100)}}

      assert {:error, %{code: :push_payload_too_large, details: %{limit: 4096}}} =
               Apns.request(base(%{aps: big}))

      assert {:ok, _request} = Apns.request(base(%{aps: big, push_type: :voip}))
    end

    test "CH-24: malformed tokens, ids and collapse ids are refused" do
      for extra <- [
            %{device_token: "xyz"},
            %{apns_id: "not-a-uuid"},
            %{collapse_id: String.duplicate("c", 65)},
            %{push_type: :unknown}
          ] do
        assert {:error, %{code: :apns_request_invalid}} = Apns.request(base(extra))
      end
    end
  end
end
