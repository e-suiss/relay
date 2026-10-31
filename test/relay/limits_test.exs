defmodule Relay.LimitsTest do
  use ExUnit.Case, async: true

  @path Path.expand("../../contracts/openapi/server.yaml", __DIR__)

  describe "X-37 API-4 single source of limits" do
    test "X-37, API-4: the limits are the contract's x-relay-limits" do
      assert Relay.Limits.all() == YamlElixir.read_from_file!(@path)["x-relay-limits"]
      assert Relay.Api.Contract.limits() == Relay.Limits.all()
    end

    test "X-37: a limit is read by its path and a duration in seconds" do
      assert Relay.Limits.fetch!(["event", "max_data_bytes"]) == 262_144
      assert Relay.Limits.seconds!(["event", "max_send_at_ahead"]) == 90 * 86_400
      assert Relay.Limits.seconds!(["support_delegation", "min"]) == 15 * 60
      assert Relay.Limits.seconds!(["support_delegation", "default"]) == 4 * 3_600
      assert_raise ArgumentError, fn -> Relay.Limits.fetch!(["event", "unknown"]) end
      assert_raise ArgumentError, fn -> Relay.Limits.seconds!(["event", "max_recipients"]) end
    end

    test "X-37, API-77: the code limits come from the contract" do
      assert Relay.Access.client_limits() == %{
               per_environment: Relay.Limits.fetch!(["api_clients_per_environment"]),
               unused_days: Relay.Limits.fetch!(["unused_api_client_warning_days"])
             }

      assert Relay.Access.SubscriberToken.lifetime_s() ==
               Relay.Limits.fetch!(["subscriber_token_lifetime_seconds"])

      assert Relay.Operators.step_up_window_s() ==
               Relay.Limits.fetch!(["operator_step_up_window_seconds"])
    end
  end
end
