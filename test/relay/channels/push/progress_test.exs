defmodule Relay.Channels.Push.ProgressTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Apns
  alias Relay.Channels.Push.Collapse
  alias Relay.Channels.Push.Fcm
  alias Relay.Channels.Push.Progress

  @tenant <<1::128>>
  @token String.duplicate("ab", 32)

  defp subject(id),
    do: %{
      tenant_id: @tenant,
      subject_type: "agent_task",
      subject_id: id,
      message_class: :operational
    }

  defp update(extra) do
    Map.merge(
      %{
        subject: subject("task-1"),
        event: :update,
        timestamp: 1_793_840_400,
        current: 3,
        total: 10
      },
      extra
    )
  end

  describe "AG-52 long-running job progress surface" do
    test "AG-52: every update of a job carries the collapse key of its subject on both platforms" do
      {:ok, first} = Progress.surface(update(%{event: :start, current: 0}), "relay.operational")
      {:ok, later} = Progress.surface(update(%{current: 7}), "relay.operational")
      key = Collapse.topic(subject("task-1"))

      assert first.topic == key
      assert later.topic == key
      assert later.fcm.notification == %{"tag" => key}
      assert later.fcm.collapse_key == "relay.operational"
      assert later.fcm.data["relay_collapse"] == key
      assert later.apns.live_activity.content_state["relay_collapse"] == key
      assert first.apns.live_activity.attributes == %{"relay_collapse" => key}
      assert first.apns.live_activity.attributes_type == Progress.attributes_type()
    end

    test "AG-52: two jobs never share a surface" do
      {:ok, one} = Progress.surface(update(%{}), "relay.operational")

      {:ok, other} =
        Progress.surface(update(%{subject: subject("task-2")}), "relay.operational")

      refute one.topic == other.topic
      refute one.fcm.notification == other.fcm.notification
    end

    test "AG-52: the Live Activity members build an APNs liveactivity request" do
      {:ok, surface} = Progress.surface(update(%{segments: [4, 6]}), "relay.operational")

      notification =
        Map.merge(surface.apns, %{
          bundle_id: "com.example.app",
          apns_id: <<7::128>>,
          apns_priority: 5,
          device_token: @token
        })

      assert {:ok, request} = Apns.request(notification)
      headers = Map.new(request.headers)
      assert headers["apns-push-type"] == "liveactivity"
      assert headers["apns-topic"] == "com.example.app.push-type.liveactivity"

      aps = Jason.decode!(request.body)["aps"]
      assert aps["event"] == "update"
      assert aps["timestamp"] == 1_793_840_400

      assert aps["content-state"] == %{
               "relay_collapse" => surface.topic,
               "current" => 3,
               "total" => 10,
               "segments" => [4, 6],
               "indeterminate" => false
             }
    end

    test "AG-52: the Android members build an FCM message whose tag replaces the job's notification" do
      {:ok, surface} = Progress.surface(update(%{event: :end, current: 10}), "relay.operational")

      message =
        Map.merge(surface.fcm, %{token: "device-token", fcm_priority: :normal, ttl: "3600s"})

      assert {:ok, built, _ignored} = Fcm.message(message)
      assert built["android"]["collapse_key"] == "relay.operational"
      assert built["android"]["notification"]["tag"] == surface.topic

      assert Jason.decode!(built["data"]["relay_progress"]) == %{
               "event" => "end",
               "current" => 10,
               "total" => 10,
               "segments" => [10],
               "indeterminate" => false
             }
    end

    test "AG-52: an update outside its total or with segments that do not add up is refused" do
      assert {:error, %Relay.Error{code: :push_progress_invalid}} =
               Progress.surface(update(%{current: 11}), "relay.operational")

      assert {:error, %Relay.Error{code: :push_progress_invalid}} =
               Progress.surface(update(%{segments: [4, 5]}), "relay.operational")

      assert {:error, %Relay.Error{code: :push_progress_invalid}} =
               Progress.surface(update(%{event: :pause}), "relay.operational")
    end
  end
end
