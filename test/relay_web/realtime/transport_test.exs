defmodule RelayWeb.Realtime.TransportTest do
  use ExUnit.Case, async: true

  alias RelayWeb.Realtime.Session
  alias RelayWeb.Realtime.Transport

  describe "IN-52 IN-33 WebSocket close codes" do
    test "IN-52: a connection over the accept rate is closed with 1013 and its Retry-After" do
      assert {:ok, {:overloaded, 3} = state} = Transport.init({:overloaded, 3})
      assert_receive :relay_realtime_overloaded

      assert {:stop, :normal, {1013, "retry-after=3"}, ^state} =
               Transport.handle_info(:relay_realtime_overloaded, state)

      assert {:ok, ^state} = Transport.handle_in({"[]", [opcode: :text]}, state)
    end

    test "IN-33: the channel closes its transport with the code and reason it names" do
      state = {:socket, :inner}

      assert {:stop, {:shutdown, :closed}, {1008, "auth_subscriber_suspended"}, ^state} =
               Transport.handle_info(
                 {:relay_realtime_close, 1008, "auth_subscriber_suspended"},
                 state
               )

      assert Session.close_code("auth_expired_token") == 1008
      assert Session.close_code("connection_limit") == 1008
      assert Session.close_code("overloaded") == 1013
    end
  end
end
