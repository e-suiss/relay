defmodule Relay.Policy.RulesTest do
  use ExUnit.Case, async: true

  alias Relay.Policy.Rules

  @stage4 ~w(
    suppression.address consent.missing consent.revoked consent.expired channel.no_address
    channel.address_disabled channel.no_permission channel_policy.otp_channel_forbidden
    channel_policy.email_verification_only scope.mismatch tenant.suspended
    preference.tenant_category preference.category_channel preference.channel preference.workflow
    preference.scope_key preference.schedule preference.category_default quiet_hours.deferred
    schedule.deferred dnd.deferred tenant_timezone_window.deferred frequency.dropped
    frequency.deferred frequency.digest frequency.inbox_only expiry.expires_at expiry.no_window
  )

  @reasons ~w(preference_off consent_missing consent_revoked suppressed_address frequency_capped
    scope_mismatch no_address no_permission channel_policy tenant_suspended expired quiet_hours
    schedule dnd tenant_timezone_window)a

  describe "DS-47 rule ids" do
    test "DS-47 (5): the lattice writes exactly the stage 4 rule ids" do
      assert Rules.ids() == Enum.sort(@stage4)
      assert Relay.Policy.rule_ids() == Rules.ids()
    end

    test "DS-47 (1): every rule id is lowercase dotted and no spec id is a rule id" do
      for id <- Rules.ids() do
        assert id =~ ~r/\A[a-z][a-z_]*(\.[a-z][a-z_]*)+\z/, id
        refute id =~ ~r/[A-Z]+-\d+/, id
      end
    end

    test "DS-25 DS-47 (3): every rule has a reason family, a kind and an outcome" do
      for name <- Rules.names() do
        assert Rules.reason(name) in @reasons, inspect(name)
        assert Rules.kind(name) in [:gate, :filter, :shaper, :terminal], inspect(name)
        assert Rules.outcome(name) in [:skip, :defer, :expire], inspect(name)
      end

      assert Rules.kind(:scope_mismatch) == :gate
      assert Rules.outcome(:frequency_digest) == :defer
      assert Rules.reason(:consent_expired) == :consent_missing
    end

    test "DS-47 (1): kill switch rules pass through with an optional reference" do
      assert Rules.kill_switch?("killswitch.engaged")
      assert Rules.kill_switch?("killswitch.bulk_cancel:abc-123")
      refute Rules.kill_switch?("rate_limit.backend_unavailable")
      refute Rules.kill_switch?("killswitch.")
      refute Rules.kill_switch?(nil)
    end
  end
end
