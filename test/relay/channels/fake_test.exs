defmodule Relay.Channels.FakeTest do
  use ExUnit.Case, async: true

  alias Relay.ChannelDeclarations
  alias Relay.Channels.Fake
  alias Relay.Channels.Outcome
  alias Relay.Channels.Request
  alias Relay.Channels.Simulated

  @results ~w(delivered sent_only delayed_delivery hard_bounce soft_bounce complaint not_delivered
              unregistered rate_limited transient_error timeout auth_error sender_config_error
              content_rejected unknown_code)

  defp request(channel, address) do
    %Request{
      scope: Relay.Scope.new!(Relay.Id.generate(), :test),
      delivery_id: Relay.Id.generate(),
      attempt_no: 1,
      channel: channel,
      provider: "fake",
      idempotency_key: "key-1",
      target: %{kind: :address, id: nil, value: Relay.Redacted.wrap(address)},
      timeout_ms: 1000
    }
  end

  describe "CH-72 X-26 simulated result table" do
    test "CH-72, X-26: the table lists the fifteen results in order with their addresses" do
      table = Simulated.table()
      assert Enum.map(table, & &1["result"]) == @results
      assert Simulated.results() == @results

      for {row, n} <- Enum.with_index(table, 1) do
        code = String.pad_leading(Integer.to_string(n), 2, "0")
        assert row["email"] == row["result"] <> "@sim.relay.test"
        assert row["phone"] == "+9905550000" <> code
        assert row["token"] == "sim:" <> row["result"]
        assert Simulated.result(:email, row["email"]) == row["result"]
        assert Simulated.result(:phone, row["phone"]) == row["result"]
        assert Simulated.result(:token, row["token"]) == row["result"]
      end

      assert Relay.Channels.simulated_results() == table
    end

    test "CH-72: every address outside the table is delivered" do
      assert Simulated.result(:email, "ada@example.com") == "delivered"
      assert Simulated.result(:email, "nothing@sim.relay.test") == "delivered"
      assert Simulated.result(:phone, "+990555000016") == "delivered"
      assert Simulated.result(:phone, "+905551112233") == "delivered"
      assert Simulated.result(:token, "sim:other") == "delivered"

      assert Relay.Channels.simulated_result("email", "Hard_Bounce@SIM.relay.test") ==
               "hard_bounce"

      assert Relay.Channels.simulated_result("sms", "+990555000004") == "hard_bounce"
      assert Relay.Channels.simulated_result("whatsapp", "sim:timeout") == "timeout"
    end

    test "CH-72, X-25: the simulated ranges are refused on the live plane" do
      assert Relay.Channels.simulated_address?("email", "a@sim.relay.test")
      assert Relay.Channels.simulated_address?("email", "a@x.sim.relay.test")
      assert Relay.Channels.simulated_address?("sms", "+990555000001")
      assert Relay.Channels.simulated_address?("voice", "+999123")
      assert Relay.Channels.simulated_address?("push", "sim:delivered")
      refute Relay.Channels.simulated_address?("email", "a@relay.test")
      refute Relay.Channels.simulated_address?("sms", "+905551112233")
      refute Relay.Channels.simulated_address?("push", "f00d")
    end
  end

  describe "X-25 X-26 fake adapter" do
    test "X-25, X-26, CH-7: the fake answers come out of the same normalization as every adapter" do
      {:ok, content} = ChannelDeclarations.compose()
      declarations = ChannelDeclarations.new(content, nil)

      expected = %{
        "delivered" => {:succeeded, nil},
        "sent_only" => {:succeeded, nil},
        "delayed_delivery" => {:succeeded, nil},
        "complaint" => {:succeeded, nil},
        "not_delivered" => {:succeeded, nil},
        "hard_bounce" => {:failed, "permanent_target"},
        "soft_bounce" => {:failed, "transient"},
        "unregistered" => {:failed, "permanent_target"},
        "rate_limited" => {:failed, "transient"},
        "transient_error" => {:failed, "transient"},
        "timeout" => {:unknown, "transient"},
        "auth_error" => {:failed, "auth"},
        "sender_config_error" => {:failed, "sender_config"},
        "content_rejected" => {:failed, "permanent_content"},
        "unknown_code" => {:failed, "unknown"}
      }

      for channel <- Fake.channels(), row <- Simulated.table() do
        address =
          case Simulated.kind(channel) do
            :email -> row["email"]
            :phone -> row["phone"]
            :token -> row["token"]
          end

        result = Fake.deliver(request(channel, address))
        assert {:ok, outcome} = Outcome.normalize(declarations, "fake", channel, result)

        assert {outcome.state, outcome.failure_class} == expected[row["result"]],
               "#{channel} #{row["result"]}"
      end
    end

    test "CH-72, DS-23: acceptances carry their follow-up events and a delay in virtual time" do
      assert {:accepted, %{followups: [%{event_code: "delivered", after_ms: 300_000}]}} =
               Fake.deliver(request("email", "delayed_delivery@sim.relay.test"))

      assert {:accepted, %{followups: [], provider_message_id: "sim_key-1"}} =
               Fake.deliver(request("sms", "+990555000002"))

      assert {:rejected, %{code: "rate_limited", status: 429, retry_after_ms: 30_000}} =
               Fake.deliver(request("push", "sim:rate_limited"))
    end

    test "T-28: the status query of an unanswered request says it was not received" do
      assert Fake.query(request("sms", "+990555000011")) == :not_received
      assert {:accepted, _info} = Fake.query(request("sms", "+990555000001"))
      assert {:rejected, %{code: "hard_bounce"}} = Fake.query(request("sms", "+990555000004"))
    end
  end
end
