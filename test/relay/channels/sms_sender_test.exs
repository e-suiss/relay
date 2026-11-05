defmodule Relay.Channels.SmsSenderTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.SmsSender

  defp tr(value, extra \\ %{}) do
    Map.merge(
      %{
        "sender_type" => "alphanumeric",
        "value" => value,
        "country" => "TR",
        "approval_state" => "approved",
        "iys_brand_code" => "654321"
      },
      extra
    )
  end

  defp ten_dlc(use_case) do
    %{
      "sender_type" => "ten_dlc",
      "value" => "+12025550123",
      "country" => "US",
      "approval_state" => "approved",
      "us_brand_id" => "BXXXXXX",
      "us_campaign_id" => "CXXXXXX",
      "us_use_case" => use_case
    }
  end

  describe "CH-50 TR sender headers" do
    test "CH-50: a TR header has 3 to 11 characters and not only digits" do
      assert SmsSender.validate(tr("ACME")) == :ok
      assert SmsSender.validate(tr("ABCDEFGHIJK")) == :ok
      assert SmsSender.validate(tr("AB")) == {:error, "channel.sender_invalid"}
      assert SmsSender.validate(tr("ABCDEFGHIJKL")) == {:error, "channel.sender_invalid"}
      assert SmsSender.validate(tr("12345")) == {:error, "channel.sender_invalid"}
      assert SmsSender.validate(tr("ACME 2")) == :ok
    end

    test "CH-50: a generic name is never a header, whatever its case" do
      assert SmsSender.validate(tr("BANKA")) == {:error, "channel.sender_generic"}
      assert SmsSender.validate(tr("Kargo")) == {:error, "channel.sender_generic"}
      assert SmsSender.validate(tr("ACMEBANKA")) == :ok
    end

    test "CH-50: a TR header needs its İYS brand code" do
      assert SmsSender.validate(tr("ACME", %{"iys_brand_code" => nil})) ==
               {:error, "channel.sender_iys_missing"}
    end

    test "CH-50: an unknown type is refused" do
      assert SmsSender.validate(tr("ACME", %{"sender_type" => "pigeon"})) ==
               {:error, "channel.sender_invalid"}

      assert SmsSender.validate(tr("ACME", %{"sender_type" => nil})) ==
               {:error, "channel.sender_invalid"}
    end
  end

  describe "CH-50 US registration" do
    test "CH-50: a 10DLC number needs its brand, campaign and use case" do
      assert SmsSender.validate(ten_dlc("2FA")) == :ok

      assert SmsSender.validate(Map.delete(ten_dlc("2FA"), "us_campaign_id")) ==
               {:error, "channel.sender_unregistered"}

      assert SmsSender.validate(ten_dlc("NOT_A_USE_CASE")) ==
               {:error, "channel.sender_unregistered"}
    end

    test "CH-50: a toll-free number needs its verification and Business Registration Number" do
      toll_free = %{
        "sender_type" => "toll_free",
        "value" => "+18885550123",
        "country" => "US",
        "approval_state" => "approved",
        "tfv_state" => "verified",
        "brn" => "12-3456789"
      }

      assert SmsSender.validate(toll_free) == :ok

      assert SmsSender.validate(Map.put(toll_free, "tfv_state", "pending")) ==
               {:error, "channel.sender_unregistered"}

      assert SmsSender.validate(Map.delete(toll_free, "brn")) ==
               {:error, "channel.sender_unregistered"}
    end

    test "CH-50: a class the campaign's use case does not cover is refused" do
      assert SmsSender.check(ten_dlc("2FA"), "security") == :ok

      assert SmsSender.check(ten_dlc("2FA"), "marketing") ==
               {:error, "channel.sender_campaign_mismatch"}

      assert SmsSender.check(ten_dlc("MARKETING"), "marketing") == :ok
      assert SmsSender.check(ten_dlc("MIXED"), "transactional") == :ok
    end
  end

  describe "CH-50 CH-14 approval" do
    test "CH-50, CH-14: nothing is sent with an identity that is not approved or is suspended" do
      assert SmsSender.check(tr("ACME"), "transactional") == :ok

      assert SmsSender.check(tr("ACME", %{"approval_state" => "pending"}), "transactional") ==
               {:error, "channel.sender_unapproved"}

      suspended = tr("ACME", %{"suspended_at" => ~U[2026-11-05 00:00:00Z]})
      assert SmsSender.check(suspended, "transactional") == {:error, "channel.sender_unapproved"}
    end
  end
end
