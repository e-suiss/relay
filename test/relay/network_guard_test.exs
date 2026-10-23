defmodule Relay.NetworkGuardTest do
  use ExUnit.Case, async: true

  alias Relay.NetworkGuard

  describe "INV-55 network calls outside transactions" do
    test "INV-55: the guard is enabled in test builds and passes outside a transaction" do
      assert NetworkGuard.enabled?()
      refute NetworkGuard.in_transaction?()

      for target <- [:valkey, :keys, :http] do
        assert NetworkGuard.check!(target) == :ok
      end
    end

    test "INV-55: the error names the call" do
      assert Exception.message(%NetworkGuard.Error{target: :valkey}) =~ ":valkey"
      assert Exception.message(%NetworkGuard.Error{target: :valkey}) =~ "INV-55"
    end
  end
end
