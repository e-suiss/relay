defmodule Relay.Tenancy.KillSwitch.AuthzTest do
  use ExUnit.Case, async: true

  alias Relay.Tenancy.KillSwitch.Authz

  @operator %{kind: :installation_operator, ref: "ops@example"}
  @later ~U[2026-10-27 14:00:00Z]

  defp spec(attrs \\ []),
    do:
      Map.merge(
        %{scope_kind: :platform, reason: "incident 42", expires_at: @later},
        Map.new(attrs)
      )

  describe "TN-41 scope table" do
    test "TN-41: campaign and workflow need a tenant operator, tenant scopes an administrator, platform the installation operator" do
      assert Authz.minimum_role(:campaign) == :tenant_operator
      assert Authz.minimum_role(:workflow) == :tenant_operator
      assert Authz.minimum_role(:tenant) == :tenant_admin
      assert Authz.minimum_role(:subtenant) == :tenant_admin
      assert Authz.minimum_role(:api_client) == :tenant_admin
      assert Authz.minimum_role(:sender) == :tenant_admin
      assert Authz.minimum_role(:platform) == :installation_operator
    end

    test "TN-41: the role order installation operator over tenant administrator over tenant operator" do
      for scope <- [:campaign, :workflow, :tenant, :subtenant, :api_client, :sender, :platform] do
        assert Authz.allowed_role?(:installation_operator, scope)
      end

      assert Authz.allowed_role?(:tenant_admin, :tenant)
      assert Authz.allowed_role?(:tenant_admin, :campaign)
      refute Authz.allowed_role?(:tenant_admin, :platform)
      assert Authz.allowed_role?(:tenant_operator, :workflow)
      refute Authz.allowed_role?(:tenant_operator, :tenant)
      refute Authz.allowed_role?(:tenant_operator, :platform)
      refute Authz.allowed_role?(:installation_operator, :unknown)
    end

    test "TN-41: an empty reason is refused" do
      assert Authz.authorize(@operator, :engage, spec(reason: " ")) == {:error, :reason_required}
      assert Authz.authorize(@operator, :engage, spec(reason: nil)) == {:error, :reason_required}
    end

    test "TN-41: a record without TTL needs its own approval" do
      assert Authz.authorize(@operator, :engage, spec(expires_at: nil)) ==
               {:error, :no_ttl_approval_required}

      assert Authz.authorize(@operator, :engage, spec(expires_at: nil, no_ttl_approval: "CAB-7")) ==
               :ok
    end
  end

  describe "TN-70 stage two actor and relaxation" do
    test "TN-70: only the installation operator acts in stage two" do
      for kind <- [:tenant_admin, :tenant_operator] do
        assert Authz.authorize(%{kind: kind, ref: "x"}, :engage, spec(scope_kind: :campaign)) ==
                 {:error, :actor_not_supported}
      end

      assert Authz.authorize(%{kind: :api_client, ref: "x"}, :engage, spec()) ==
               {:error, :actor_not_supported}

      assert Authz.authorize(@operator, :engage, spec()) == :ok
    end

    test "TN-70: release, resume and a relaxing replace need the relax approval" do
      for action <- [:release, :resume] do
        assert Authz.authorize(@operator, action, spec()) == {:error, :relax_approval_required}
        assert Authz.authorize(@operator, action, spec(relax_approval: "CAB-9")) == :ok
      end

      assert Authz.authorize(@operator, :replace, spec(relaxes?: true)) ==
               {:error, :relax_approval_required}

      assert Authz.authorize(@operator, :replace, spec(relaxes?: false)) == :ok
      assert Authz.authorize(@operator, :bulk_cancel, spec()) == :ok
    end

    test "TN-70: relaxing means a lower rank or, at the same rank, an earlier pause, a higher canary or an earlier expiry" do
      at = ~U[2026-10-27 13:00:00Z]
      off = %{state: :off, canary_percent: nil, paused_until: nil, expires_at: @later}

      assert Authz.relaxes?(off, %{off | state: :on})
      assert Authz.relaxes?(off, %{off | state: :canary, canary_percent: 5})
      refute Authz.relaxes?(off, off)
      refute Authz.relaxes?(%{off | state: :canary, canary_percent: 5}, off)

      paused = %{off | state: :paused_until, paused_until: @later}
      assert Authz.relaxes?(paused, %{paused | paused_until: at})
      refute Authz.relaxes?(%{paused | paused_until: at}, paused)
      assert Authz.relaxes?(%{paused | paused_until: nil}, paused)

      canary = %{off | state: :canary, canary_percent: 10}
      assert Authz.relaxes?(canary, %{canary | canary_percent: 20})
      refute Authz.relaxes?(canary, %{canary | canary_percent: 5})

      assert Authz.relaxes?(off, %{off | expires_at: at})
      assert Authz.relaxes?(%{off | expires_at: nil}, off)
      refute Authz.relaxes?(off, %{off | expires_at: nil})
    end
  end

  describe "TN-42 security approval" do
    test "TN-42: stopping security needs its own approval" do
      assert Authz.authorize(@operator, :engage, spec(message_class: "security")) ==
               {:error, :security_approval_required}

      assert Authz.authorize(@operator, :engage, spec(message_class: :security)) ==
               {:error, :security_approval_required}

      assert Authz.authorize(
               @operator,
               :engage,
               spec(message_class: "security", security_approval: "SEC-1")
             ) == :ok
    end
  end
end
