defmodule Relay.Compliance.IysChannelTest do
  use ExUnit.Case, async: true

  alias Relay.Compliance.IysChannel

  describe "CH-56 İYS channel of a Relay channel" do
    test "CH-56: a commercial voice message is subject to İYS ARAMA" do
      assert IysChannel.of("voice") == {:ok, "ARAMA"}
      assert IysChannel.of(:voice) == {:ok, "ARAMA"}
      assert IysChannel.covered?("voice")
    end

    test "CH-56: SMS is MESAJ and e-mail is EPOSTA" do
      assert IysChannel.of("sms") == {:ok, "MESAJ"}
      assert IysChannel.of("email") == {:ok, "EPOSTA"}
      assert IysChannel.channels() == ["email", "sms", "voice"]
      assert IysChannel.all() == ["ARAMA", "EPOSTA", "MESAJ"]
    end

    test "CH-56: a channel İYS does not cover has no İYS channel" do
      for channel <- ~w(push web_push whatsapp in_app slack teams telegram discord webhook) do
        assert IysChannel.of(channel) == :none
        refute IysChannel.covered?(channel)
      end

      assert IysChannel.of(nil) == :none
    end
  end
end
