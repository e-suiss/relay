defmodule Relay.Operators.AuthzTest do
  use ExUnit.Case, async: true

  alias Relay.Operators.Authz

  @installation Relay.Id.generate()
  @tenant Relay.Id.generate()

  defp grant(tenant, environment, role),
    do: %{tenant_id: tenant, environment: environment, role: role}

  defp context(scope, opts \\ []) do
    Map.merge(
      %{installation_tenant_id: @installation, scope: scope, delegation_id: nil, reads?: false},
      Map.new(opts)
    )
  end

  describe "TN-19 TN-23 role matrix" do
    test "TN-23: roles rank installation operator above tenant administrator above tenant operator" do
      assert Enum.map(Authz.roles(), &Authz.rank/1) == [3, 2, 1]
    end

    test "TN-19: an operation without a role needs only a session" do
      assert Authz.authorize([], nil, context(nil)) == {:ok, :own}
    end

    test "TN-19: a tenant role counts only in its own tenant and environment" do
      live = Relay.Scope.new!(@tenant, :live)
      test = Relay.Scope.new!(@tenant, :test)
      grants = [grant(@tenant, :live, :tenant_admin)]

      assert Authz.authorize(grants, :tenant_admin, context(live)) == {:ok, :own}
      assert Authz.authorize(grants, :tenant_operator, context(live)) == {:ok, :own}

      assert {:error, :insufficient_role, %{required: :tenant_admin, granted: []}} =
               Authz.authorize(grants, :tenant_admin, context(test))
    end

    test "TN-23: the installation operator holds no tenant role in another tenant" do
      live = Relay.Scope.new!(@tenant, :live)
      grants = [grant(@installation, :live, :installation_operator)]

      assert Authz.authorize(grants, :installation_operator, context(nil)) == {:ok, :own}

      assert {:error, :delegation_required, _} =
               Authz.authorize(grants, :tenant_operator, context(live, reads?: true))

      installation = Relay.Scope.new!(@installation, :live)
      assert Authz.authorize(grants, :tenant_admin, context(installation)) == {:ok, :own}
    end

    test "TN-23: a support delegation allows reading on the tenant's behalf, never writing or revealing" do
      live = Relay.Scope.new!(@tenant, :live)
      grants = [grant(@installation, :live, :installation_operator)]
      delegation = Relay.Id.generate()

      assert Authz.authorize(
               grants,
               :tenant_admin,
               context(live, delegation_id: delegation, reads?: true)
             ) == {:ok, {:delegated, delegation}}

      assert {:error, :insufficient_role, _} =
               Authz.authorize(grants, :tenant_admin, context(live, delegation_id: delegation))

      assert {:error, :insufficient_role, _} =
               Authz.authorize(
                 grants,
                 :tenant_admin,
                 context(live, delegation_id: delegation, reads?: true, reveal?: true)
               )
    end

    test "X-4: a tenant role never reaches an installation operation" do
      grants = [grant(@tenant, :live, :tenant_admin)]

      assert {:error, :insufficient_role, %{required: :installation_operator}} =
               Authz.authorize(grants, :installation_operator, context(nil))
    end
  end

  describe "TN-22 OP-51 relaxation" do
    test "TN-22: a send mode closer to live relaxes, a stricter one tightens" do
      assert Authz.send_mode_relaxes?("off", "shadow")
      assert Authz.send_mode_relaxes?("dry_run", "live")
      assert Authz.send_mode_relaxes?("off", nil)
      refute Authz.send_mode_relaxes?(nil, "off")
      refute Authz.send_mode_relaxes?("shadow", "dry_run")
      refute Authz.send_mode_relaxes?("live", "live")
    end
  end

  defp policy(limit, caps \\ %{"marketing" => 5_000}, reserve \\ 1_000),
    do: %{limit_total: limit, class_caps: caps, security_reserve_bp: reserve}

  describe "TN-72 quota changes" do
    test "TN-72: creating, removing and raising a policy raise; lowering does not" do
      current = policy(1_000)

      for raised <- [
            policy(2_000),
            policy(1_000, %{"marketing" => 6_000}),
            policy(1_000, %{}),
            policy(1_000, %{"marketing" => 5_000}, 1_500),
            policy(nil)
          ] do
        assert Authz.quota_raises?(current, raised)
      end

      assert Authz.quota_raises?(policy(nil), policy(1_000))

      for lowered <- [
            policy(900),
            policy(1_000, %{"marketing" => 4_000}),
            policy(1_000, %{"marketing" => 5_000, "social" => 9_000}),
            policy(1_000, %{"marketing" => 5_000}, 500),
            current
          ] do
        refute Authz.quota_raises?(current, lowered)
      end
    end

    test "TN-72: the installation operator passes a by-change operation in any tenant" do
      scope = Relay.Scope.new!(@tenant, :live)
      operator = [grant(@installation, :live, :installation_operator)]
      admin = [grant(@tenant, :live, :tenant_admin)]
      allowed = context(scope, installation_allowed?: true)

      assert Authz.authorize(operator, :tenant_admin, allowed) == {:ok, :own}

      assert {:error, :delegation_required, _details} =
               Authz.authorize(operator, :tenant_admin, context(scope))

      both = [:tenant_admin, :installation_operator]
      assert Authz.holds_any?(operator, both, scope, @installation)
      refute Authz.holds_any?(operator, [:tenant_admin], scope, @installation)
      assert Authz.holds_any?(admin, both, scope, @installation)
      refute Authz.holds_any?(admin, [:installation_operator], scope, @installation)

      other = Relay.Scope.new!(Relay.Id.generate(), :live)
      refute Authz.holds_any?(admin, both, other, @installation)
    end
  end
end
