defmodule Relay.Channels.Push.AccessGrantTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Push.AccessGrant
  alias Relay.Channels.Push.Interruption

  defp query do
    %{
      tenant_id: Relay.Id.generate(),
      recipient_ref: "acc_party_1",
      sender_ref: "acc_client_1",
      template_ref: "flight-cancelled"
    }
  end

  describe "CH-66 Access Grant" do
    test "E-107: the Grant is asked as the critical action of the relay.interrupt namespace" do
      assert AccessGrant.action() == %{namespace: "relay.interrupt", name: "critical"}
    end

    test "E-107: until Access names the endpoint every answer is fail-closed" do
      for sender <- ["acc_client_1", "agent-1"] do
        query = %{query() | sender_ref: sender}
        assert Relay.Channels.critical_grant(query) == :unavailable
      end
    end

    test "CH-66: without an Access decision for the Grant the answer is unavailable" do
      assert {:error, %Relay.Error{code: :service_unavailable}} = AccessGrant.evaluate(query())
      assert Relay.Channels.critical_grant(query()) == :unavailable
    end

    test "CH-66: an unavailable Grant delivers at the class ceiling with critical_not_granted" do
      result =
        Interruption.resolve(%{
          message_class: :security,
          requested: :critical,
          default: :time_sensitive,
          ceiling: :time_sensitive,
          critical_enabled: true,
          critical_declared: true,
          grant: fn -> Relay.Channels.critical_grant(query()) end
        })

      assert result.level == :time_sensitive
      assert result.reasons == [:critical_not_granted]
    end
  end
end
