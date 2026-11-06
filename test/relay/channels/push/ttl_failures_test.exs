defmodule Relay.Channels.Push.TtlFailuresTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Ttl

  @now ~U[2026-11-05 00:00:00Z]
  @fcm_error "type.googleapis.com/google.firebase.fcm.v1.FcmError"
  @readers %{
    "apns" => :apns,
    "fcm" => :fcm,
    "hms" => :hms,
    "web_push" => :web_push,
    "unified_push" => :web_push
  }

  defp vectors(provider) do
    ["priv/channels", provider, "vectors.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  describe "CH-9 time to live" do
    test "CH-9: channel TTLs derive from expires_at minus now" do
      expires_at = DateTime.add(@now, 3_600, :second)

      assert Ttl.remaining(expires_at, @now) == {:ok, 3_600}
      assert Ttl.apns_expiration(expires_at, @now) == {:ok, DateTime.to_unix(expires_at)}
      assert Ttl.fcm(expires_at, @now) == {:ok, "3600s"}
      assert Ttl.web_push(expires_at, @now) == {:ok, 3_600}
    end

    test "CH-9: an expired message is not sent and no expiry means the maximum" do
      assert Ttl.remaining(@now, @now) == :expired
      assert Ttl.apns_expiration(DateTime.add(@now, -1, :second), @now) == :expired
      assert Ttl.fcm(@now, @now) == :expired
      assert Ttl.apns_expiration(nil, @now) == {:ok, nil}
      assert Ttl.fcm(nil, @now) == {:ok, "2419200s"}
      assert Ttl.web_push(DateTime.add(@now, 90, :day), @now) == {:ok, 2_419_200}
    end
  end

  describe "CH-7 failure codes" do
    test "CH-7, DS-11: every vector's response reads as its raw code" do
      for {provider, reader} <- @readers,
          vector <- vectors(provider),
          Map.has_key?(vector, "response") do
        assert Failures.code(reader, vector["response"]) == vector["raw"]["code"],
               "#{provider} #{vector["name"]}"
      end
    end

    test "CH-8: an unmapped code is reported raw, never guessed" do
      body = ~s({"reason":"SomethingNew"})

      assert {:rejected, %{code: "400/SomethingNew", status: 400}} =
               Failures.read(:apns, %{status: 400, body: body}, @now)

      body = %{"error" => %{"status" => "NOT_FOUND"}}

      assert {:rejected, %{code: "rpc:NOT_FOUND"}} =
               Failures.read(:fcm, %{status: 404, body: body}, @now)
    end

    test "CH-11: an APNs 410 carries the time the token became invalid" do
      body = %{"reason" => "Unregistered", "timestamp" => 1_793_836_800_000}

      assert {:rejected, %{code: "410/Unregistered", timestamp: at}} =
               Failures.read(:apns, %{status: 410, body: body}, @now)

      assert at == DateTime.from_unix!(1_793_836_800_000, :millisecond)
    end

    test "CH-9: the Retry-After delay is read" do
      response = %{status: 429, body: "", headers: [{"retry-after", "30"}]}

      assert {:rejected, %{code: "429", retry_after_ms: 30_000}} =
               Failures.read(:web_push, response, @now)
    end

    test "CH-32: acceptance is not delivery and an HMS answer needs its success code" do
      assert Failures.read(:apns, %{status: 200, body: ""}, @now) == :accepted
      assert Failures.read(:fcm, %{status: 200, body: %{"name" => "m"}}, @now) == :accepted
      assert Failures.read(:web_push, %{status: 201, body: nil}, @now) == :accepted

      assert Failures.read(:hms, %{status: 200, body: %{"code" => "80000000"}}, @now) ==
               :accepted

      assert {:rejected, %{code: "80100000"}} =
               Failures.read(:hms, %{status: 200, body: %{"code" => "80100000"}}, @now)
    end

    test "CH-7: the FCM error code wins over the status" do
      body = %{
        "error" => %{
          "status" => "NOT_FOUND",
          "details" => [%{"@type" => @fcm_error, "errorCode" => "UNREGISTERED"}]
        }
      }

      assert {:rejected, %{code: "UNREGISTERED", status: 404}} =
               Failures.read(:fcm, %{status: 404, body: body}, @now)
    end
  end
end
