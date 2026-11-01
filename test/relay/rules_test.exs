defmodule Relay.RulesTest do
  use Relay.DataCase, async: true

  alias Relay.Rules

  describe "DS-47 rule lookup" do
    test "DS-47 (3): a recorded rule id resolves to its reason family and explanation" do
      assert {:ok, "preference_off"} = Rules.reason("preference.category_channel")
      assert {:ok, "scope_mismatch"} = Rules.reason("scope.mismatch")
      assert {:ok, sentence} = Rules.describe("suppression.address", "tr")
      assert sentence =~ "bastırma"
      assert {:ok, "Not sent because" <> _} = Rules.describe("consent.missing", "en")
    end

    test "DS-47 (1): the reference after the colon does not take part in the lookup" do
      assert {:ok, %{"id" => "killswitch.bulk_cancel"}} =
               Rules.entry("killswitch.bulk_cancel:ksw_01j9zq3k4m5n6p7q8r9s0t1v2w")

      assert Rules.known?("rate_limit.limit:test.g1")
      assert Rules.known?("breaker.provider:acme_sms")
    end

    test "DS-47 (1): an unknown or malformed rule id is an error, never a guess" do
      assert {:error, %Relay.Error{code: :unknown_rule}} = Rules.entry("preference.unknown")
      assert {:error, %Relay.Error{code: :invalid_rule_id}} = Rules.entry("TN-5")
      refute Rules.known?("quiet_hours")
    end

    test "DS-47 (2): without an active version the bundled dictionary is used" do
      assert Rules.dictionary() ==
               Relay.RuleDictionary.index(Relay.RuleDictionary.bundled())
    end
  end
end
