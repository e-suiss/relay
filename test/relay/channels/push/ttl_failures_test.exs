defmodule Relay.Channels.Push.TtlFailuresTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.Failures
  alias Relay.Channels.Push.Ttl

  @now ~U[2026-11-05 00:00:00Z]

  defp vectors(provider) do
    ["priv/push", Atom.to_string(provider), "vectors.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("vectors")
  end

  defp response(%{"status" => status, "body" => body}), do: %{status: status, body: body}

  @fcm_error "type.googleapis.com/google.firebase.fcm.v1.FcmError"

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

  describe "CH-7 failure tables" do
    test "CH-7: every vector classifies to its class and rule" do
      for provider <- Failures.providers(), vector <- vectors(provider) do
        assert {:failure, failure} = Failures.classify(provider, response(vector["response"]))
        assert Atom.to_string(failure.class) == vector["class"], inspect(vector)
        assert failure.rule == vector["rule"], inspect(vector)
      end
    end

    test "CH-7: every rule has a vector and the tables carry their source" do
      for provider <- Failures.providers() do
        table = Failures.table(provider)
        assert table["provider"] == Atom.to_string(provider)
        assert String.starts_with?(table["source"], "https://")
        assert {:ok, _date} = Date.from_iso8601(table["compiled_at"])

        covered = MapSet.new(vectors(provider), & &1["rule"])
        ids = Enum.map(table["rules"], & &1["id"])
        assert ids == Enum.uniq(ids)
        assert Enum.all?(ids, &MapSet.member?(covered, &1)), inspect(provider)
      end
    end

    test "CH-8: an unmapped code is unknown, never guessed" do
      assert {:failure, %{class: :unknown, rule: nil, provider_code: "400/SomethingNew"}} =
               Failures.classify(:apns, %{status: 400, body: ~s({"reason":"SomethingNew"})})

      body = %{"error" => %{"status" => "NOT_FOUND"}}

      assert {:failure, %{class: :unknown, provider_code: "404/NOT_FOUND"}} =
               Failures.classify(:fcm, %{status: 404, body: body})
    end

    test "CH-11: an APNs 410 carries the time the token became invalid" do
      body = %{"reason" => "Unregistered", "timestamp" => 1_793_836_800_000}

      assert {:failure, %{class: :permanent_target, unregistered_at: 1_793_836_800_000}} =
               Failures.classify(:apns, %{status: 410, body: body})
    end

    test "CH-32: acceptance is not delivery" do
      assert Failures.classify(:apns, %{status: 200, body: ""}) == :accepted
      assert Failures.classify(:fcm, %{status: 200, body: %{"name" => "m"}}) == :accepted
      assert Failures.classify(:web_push, %{status: 201, body: nil}) == :accepted
    end

    test "CH-7: the FCM error code wins over the status" do
      body = %{
        "error" => %{
          "status" => "NOT_FOUND",
          "details" => [%{"@type" => @fcm_error, "errorCode" => "UNREGISTERED"}]
        }
      }

      assert {:failure, failure} = Failures.classify(:fcm, %{status: 404, body: body})
      assert %{class: :permanent_target, provider_code: "404/NOT_FOUND/UNREGISTERED"} = failure
    end
  end
end
