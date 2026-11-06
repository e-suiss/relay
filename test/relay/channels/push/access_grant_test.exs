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
