defmodule Relay.Ingest.SendModeTest do
  use ExUnit.Case, async: true

  describe "OP-51 resolution order" do
    test "OP-51: request, category and channel, channel, tenant, then installation decide" do
      all = %{
        "send_mode.category.orders.channel.email" => "shadow",
        "send_mode.channel.email" => "off",
        "send_mode" => "dry_run"
      }

      assert Relay.Ingest.send_mode("live", all, "orders", "email") == :live
      assert Relay.Ingest.send_mode(nil, all, "orders", "email") == :shadow
      assert Relay.Ingest.send_mode(nil, all, "billing", "email") == :off
      assert Relay.Ingest.send_mode(nil, all, "billing", "sms") == :dry_run
      assert Relay.Ingest.send_mode(nil, %{}, "billing", "sms") == :live
      assert Relay.Ingest.send_mode(nil, %{}, "billing", "sms", "shadow") == :shadow
      assert Relay.Ingest.send_mode(nil, all, "billing", "sms", "off") == :dry_run
      assert Relay.Ingest.send_mode("live", %{}, "billing", "sms", "off") == :live
      assert Relay.Ingest.send_mode(nil, %{}, "billing", "sms", nil) == :live
    end
  end
end
