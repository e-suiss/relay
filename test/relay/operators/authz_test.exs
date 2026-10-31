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
end
