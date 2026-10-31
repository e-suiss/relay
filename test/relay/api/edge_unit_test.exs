defmodule Relay.Api.EdgeUnitTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Relay.Api.Idempotency
  alias Relay.Api.RateLimit
  alias Relay.Tenancy.SettingKeys
  alias RelayWeb.Api.Admission
  alias RelayWeb.Api.Beta
  alias RelayWeb.Api.Transport

  defp no_derive, do: :none

  describe "API-10 and API-11 idempotency keys" do
    test "API-10: a mutating operation needs the header; a derived one without it needs a derived key" do
      assert {:error, %Relay.Error{code: :idempotency_key_missing}} =
               Idempotency.key(:required, [], &no_derive/0)

      assert {:error, %Relay.Error{code: :idempotency_key_missing}} =
               Idempotency.key(:derived, [], &no_derive/0)

      assert {:ok, "ce_derived"} = Idempotency.key(:derived, [], fn -> {:ok, "ce_derived"} end)
      assert {:ok, "header-key"} = Idempotency.key(:derived, ["header-key"], &no_derive/0)
    end

    test "API-10: an operation without idempotency ignores the header" do
      assert {:ok, nil} = Idempotency.key(:not_applicable, ["x"], &no_derive/0)
    end

    test "API-11: 8 to 255 characters, quoted or not" do
      assert {:ok, "abcdefgh"} = Idempotency.key(:required, [~s("abcdefgh")], &no_derive/0)
      assert {:ok, "abcdefgh"} = Idempotency.key(:required, ["abcdefgh"], &no_derive/0)

      for bad <- ["abcdefg", String.duplicate("k", 256)] do
        assert {:error, %Relay.Error{code: :idempotency_key_invalid}} =
                 Idempotency.key(:required, [bad], &no_derive/0)
      end
    end
  end

  describe "API-50 and API-77 rate limit values" do
    test "API-77 (4): the tenant tiers default to 200 per second and 6000 per minute" do
      assert [
               %{name: "burst", quota: 200, window_s: 1},
               %{name: "sustained", quota: 6000, window_s: 60}
             ] = RateLimit.tiers(%{})
    end

    test "API-77 (4): tiers are tenant settings and a client sub-limit applies only below them" do
      settings = %{"api.rate.burst" => %{"weight" => 50, "window_seconds" => 1}}
      client = %{id: "cli_1", tiers: %{"burst" => %{"weight" => 10, "window_seconds" => 1}}}
      equal = %{id: "cli_1", tiers: %{"burst" => %{"weight" => 50, "window_seconds" => 1}}}

      assert [
               %{quota: 50},
               %{quota: 6000},
               %{name: "client_burst", quota: 10, parts: ["cli_1"]}
             ] = RateLimit.tiers(settings, client)

      assert length(RateLimit.tiers(settings, equal)) == 2
    end

    test "API-77 (4): a rate setting is checked when it is written" do
      value = %{"weight" => 100, "window_seconds" => 1}
      assert {:ok, ^value} = SettingKeys.cast("api.rate.burst", value)
      assert {:ok, nil} = SettingKeys.cast("api.rate.sustained", nil)

      for bad <- [%{"weight" => 0, "window_seconds" => 1}, %{"weight" => 5}, 5] do
        assert {:error, %Relay.Error{code: :invalid_setting}} =
                 SettingKeys.cast("api.rate.burst", bad)
      end
    end
  end

  describe "T-35 admission at the edge" do
    test "API-51: overload is 503 with Retry-After, never 429, and security is never refused" do
      shed = %{l1: true, l2: true, l3: true}
      input = %{channels: [:email], shed: shed, breaker_open: MapSet.new(), lane_capacity: nil}

      assert :ok = Admission.decide(Map.put(input, :message_class, :security))
      assert :ok = Admission.decide(Map.put(input, :message_class, :transactional))

      assert {:error, %Relay.Error{code: :service_unavailable, details: %{retry_after: 60}}} =
               Admission.decide(Map.put(input, :message_class, :operational))

      assert {:error, %Relay.Error{code: :service_unavailable, details: %{retry_after: 1800}}} =
               Admission.decide(Map.put(input, :message_class, :marketing))
    end
  end

  describe "INV-2 durability at the edge" do
    test "INV-2: a database that cannot serve is 503 with Retry-After, any other failure 500" do
      conn = conn(:post, "https://relay.test/v1/events")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          unavailable =
            RelayWeb.Api.Response.exception(
              conn,
              %DBConnection.ConnectionError{message: "pool timeout"},
              []
            )

          assert unavailable.status == 503
          assert Plug.Conn.get_resp_header(unavailable, "retry-after") == ["5"]
          assert Jason.decode!(unavailable.resp_body)["code"] == "service_unavailable"

          crashed = RelayWeb.Api.Response.exception(conn, %RuntimeError{message: "boom"}, [])
          assert crashed.status == 500
          refute crashed.resp_body =~ "boom"
        end)

      assert log =~ "pool timeout"
    end
  end

  describe "API-8 transport and API-55 beta" do
    test "API-8: plain HTTP is refused unless a trusted proxy says HTTPS" do
      plain = %{conn(:get, "http://relay.test/v1/x") | remote_ip: {10, 0, 0, 5}}
      forwarded = Plug.Conn.put_req_header(plain, "x-forwarded-proto", "https")

      assert Transport.scheme(plain, ["10.0.0.0/8"]) == :http
      assert Transport.scheme(forwarded, ["10.0.0.0/8"]) == :https
      assert Transport.scheme(forwarded, []) == :http
      assert Transport.scheme(forwarded, ["192.168.0.0/16"]) == :http
      assert Transport.hsts() =~ "max-age="
    end

    test "API-47: the client address comes from X-Forwarded-For only behind a trusted proxy" do
      conn =
        %{conn(:get, "https://relay.test/v1/x") | remote_ip: {10, 0, 0, 5}}
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7, 10.0.0.9")

      assert Transport.client_ip(conn, ["10.0.0.0/8"]) == {203, 0, 113, 7}
      assert Transport.client_ip(conn, []) == {10, 0, 0, 5}
      assert Transport.trusted?({0, 0, 0, 0, 0, 0, 0, 1}, ["::1/128"])
    end

    test "API-55: an unknown beta feature is refused and a beta response is marked" do
      assert {:ok, []} = Beta.parse([])
      assert {:error, %Relay.Error{code: :unsupported_beta_feature}} = Beta.parse(["time_travel"])
      assert {:ok, ["digest_v2"]} = Beta.parse(["digest_v2, digest_v2"], ["digest_v2"])
      assert Beta.mark(%{"a" => 1}) == %{"a" => 1, "beta" => true}
    end
  end
end
