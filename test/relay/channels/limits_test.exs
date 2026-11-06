defmodule Relay.Channels.LimitsTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Limits
  alias Relay.Channels.Throttle

  @account_id <<1::128>>

  defp declaration do
    %{
      "limits" => %{
        "account" => [
          %{"channel" => "sms", "unit" => "segment", "limit" => 100, "per_ms" => 1000},
          %{"channel" => "email", "unit" => "recipient", "limit" => 50, "per_ms" => 1000}
        ],
        "sender" => [%{"channel" => "sms", "unit" => "segment", "limit" => 10, "per_ms" => 1000}],
        "recipient" => [
          %{"channel" => "email", "unit" => "recipient", "limit" => 20, "per_ms" => 60_000}
        ]
      }
    }
  end

  defp account(ownership \\ "tenant"),
    do: %{"id" => @account_id, "provider" => "netgsm", "ownership" => ownership}

  describe "CH-17 provider limits" do
    test "CH-17, T-20 (4): each declared layer of the channel is a stricter GCRA limit" do
      call = %{channel: "sms", account: account(), target: "+905551112233", content: %{}}

      assert [account, sender] = Limits.checks(declaration(), call)
      assert account.layer == "account"
      assert account.attrs.limit == 90
      assert account.attrs.burst == 90
      assert account.attrs.unit == :segment
      assert account.attrs.ceiling
      assert sender.layer == "sender"
      assert sender.attrs.limit == 9
      refute sender.attrs.ceiling
      assert {:ok, _limit} = Relay.Platform.rate_limit(account.attrs)
      assert {:ok, _limit} = Relay.Platform.rate_limit(sender.attrs)
    end

    test "CH-17, T-19: the cost is in the channel's unit" do
      call = %{channel: "sms", account: account(), target: "+905551112233"}

      assert [%{cost: 3}, %{cost: 3}] =
               Limits.checks(declaration(), Map.put(call, :content, %{"segments" => 3}))

      assert Limits.cost("email", %{}) == 1
      assert Limits.cost("sms", nil) == 1
    end

    test "CH-17: email has one recipient bucket per recipient domain" do
      call = %{channel: "email", account: account(), target: "Ayse@Gmail.com"}
      [_account, recipient] = Limits.checks(declaration(), call)

      assert recipient.layer == "recipient"
      assert List.last(recipient.key_parts) == "gmail.com"
      assert Limits.bucket("sms", "+905551112233") =~ ~r/\A[0-9a-f]{32}\z/
    end

    test "TN-53, T-33: a shared account's quota is keyed by its provider with the ceiling" do
      call = %{channel: "sms", account: account("shared"), target: "+905551112233"}
      [shared, own] = Limits.checks(declaration(), call)

      assert shared.shared
      assert shared.key_parts == ["sms", "netgsm"]
      refute own.shared

      [tenant | _rest] = Limits.checks(declaration(), %{call | account: account()})
      refute tenant.shared
      assert tenant.key_parts == ["sms", Base.encode16(@account_id, case: :lower)]
    end

    test "CH-17: without a declaration or a row of the channel there is no check" do
      assert Limits.checks(nil, %{channel: "sms", account: account(), target: "x"}) == []
      push = %{channel: "push", account: account(), target: "x"}
      assert Limits.checks(declaration(), push) == []
    end

    test "CH-17: the adaptive factor scales only the account layer" do
      call = %{channel: "sms", account: account(), target: "+905551112233", factor: 0.5}
      assert [%{attrs: %{limit: 45}}, %{attrs: %{limit: 9}}] = Limits.checks(declaration(), call)
    end
  end

  describe "CH-17 adaptive throttle" do
    test "CH-17: a throttled call halves the factor, a success raises it slowly" do
      assert Throttle.step(1.0, :throttled) == 0.5
      assert Throttle.step(0.15, :throttled) == 0.1
      assert Throttle.step(0.5, :success) == 0.55
      assert Throttle.step(0.98, :success) == 1.0
    end

    test "CH-17: an account's factor moves with its answers" do
      id = Relay.Id.generate()
      assert Throttle.factor(id) == 1.0
      assert :ok = Throttle.record(id, :throttled)
      assert :ok = Throttle.record(id, :success)
      _ = :sys.get_state(Throttle)
      assert Throttle.factor(id) == 0.55
      assert Throttle.factor(nil) == 1.0
    end
  end
end
