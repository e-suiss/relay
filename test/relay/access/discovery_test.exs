defmodule Relay.Access.DiscoveryTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Link
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture
  alias RelayWeb.Auth.Access

  @link "SELECT issuer, state, access_region, management_api, event_subscriptions, authzen IS NOT NULL, jwks FROM relay.access_link"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    client = FakeAccess.client!(tenant.test, ["read"])
    token = FakeAccess.server_token(tenant.attrs.access_tenant_id, client, "read")
    on_exit(fn -> Link.put(Link.snapshot(nil, FakeAccess.issuer())) end)
    %{tenant: tenant, token: token}
  end

  defp verify(token),
    do: Relay.Access.verify_server_token(token, audience: Access.audience(:server))

  defp other_region do
    Enum.find(["tr", "eu", "us"], &(&1 != FakeAccess.installation_region()))
  end

  describe "E-78 E-40 discovery" do
    test "E-78, E-40: the issuer alone links Relay: discovery, AuthZEN and the public keys are fetched and cached" do
      assert Relay.Access.link_state() == :ok
      assert Relay.Access.issuer() == FakeAccess.issuer()

      assert [[issuer, "ok", region, management, events, true, jwks]] =
               Relay.Repo.query!(@link, []).rows

      assert issuer == FakeAccess.issuer()
      assert region == FakeAccess.installation_region()
      assert management == FakeAccess.issuer() <> "/management"
      assert events == FakeAccess.issuer() <> "/event-subscriptions"
      assert jwks == FakeAccess.jwks()

      assert %{token_endpoint: endpoint, keys: [_, _]} = Link.current()
      assert endpoint == FakeAccess.issuer() <> "/oauth2/token"
    end

    test "E-78: a key set with private members is not taken and the last keys stay", ctx do
      assert {:error, %Relay.Error{}} =
               Relay.Access.refresh(http: [plug: {FakeAccess, keys: :private}])

      assert Relay.Access.link_state() == :stale
      assert {:ok, _principal} = verify(ctx.token)
    end
  end

  describe "INV-41 E-39 TN-57 same region" do
    test "INV-41, E-39, TN-57: Access in another region is refused: no link, no keys, no verification",
         ctx do
      region = other_region()

      assert {:error, %Relay.Error{code: :access_region_mismatch}} =
               Relay.Access.refresh(http: [plug: {FakeAccess, region: region}])

      assert Relay.Access.link_state() == :region_mismatch
      assert %{keys: []} = Link.current()

      assert [[_, "region_mismatch", ^region, nil, nil, false, nil]] =
               Relay.Repo.query!(@link, []).rows

      assert {:error, %Relay.Error{code: :service_unavailable}} = verify(ctx.token)

      envelope = FakeAccess.event("tenant.created", %{"access_tenant_id" => "acc_x"})
      assert FakeAccess.deliver(envelope).status == 503
    end
  end

  describe "E-5 E-75 availability" do
    test "E-75: when Access cannot be reached the cached keys keep verifying and the link is stale",
         ctx do
      assert {:error, %Relay.Error{code: :access_unreachable}} =
               Relay.Access.refresh(http: [plug: {FakeAccess, down: true}])

      assert Relay.Access.link_state() == :stale
      assert [[_, "stale", _, _, _, true, _]] = Relay.Repo.query!(@link, []).rows
      assert {:ok, principal} = verify(ctx.token)
      assert principal.scope == ctx.tenant.test

      assert {:ok, :ok} = Relay.Access.refresh()
      assert Relay.Access.link_state() == :ok
    end

    test "E-5: a node starts without waiting for Access; until the first fetch tokens get service_unavailable",
         ctx do
      :ok = Link.put(Link.snapshot(nil, FakeAccess.issuer()))

      assert Relay.Access.link_state() == :pending
      assert {:error, %Relay.Error{code: :service_unavailable}} = verify(ctx.token)

      assert {:ok, _snapshot} = Link.reload()
      assert {:ok, _principal} = verify(ctx.token)
    end

    test "E-78: a cached link of another issuer is no link" do
      row = %{
        issuer: "https://other.test",
        state: "ok",
        discovery: nil,
        authzen: nil,
        jwks: FakeAccess.jwks(),
        access_region: "tr",
        management_api: nil,
        event_subscriptions: nil,
        fetched_at: nil
      }

      issuer = FakeAccess.issuer()
      assert %{state: :pending, keys: []} = Link.snapshot(row, issuer)
      assert %{state: :ok, keys: [_, _]} = Link.snapshot(%{row | issuer: issuer}, issuer)
    end
  end
end
