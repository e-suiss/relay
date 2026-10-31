defmodule Relay.Access.PlatformTenantTest do
  use Relay.DataCase, async: false

  alias Relay.Access.ClientStore
  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    :ok
  end

  defp deliver!(type, data) do
    envelope = FakeAccess.event(type, data)
    conn = FakeAccess.deliver(envelope)
    assert conn.status == 204
    Api.assert_contract(conn)
    envelope["id"]
  end

  defp receipt_of(webhook_id) do
    FakeAccess.drain!()
    |> Enum.map(&FakeAccess.receipt/1)
    |> Enum.find(&(&1["webhook_id"] == webhook_id))
  end

  defp tenant_data(access_tenant_id) do
    %{
      "access_tenant_id" => access_tenant_id,
      "region" => FakeAccess.installation_region(),
      "default_timezone" => "Europe/Istanbul",
      "default_locale" => "tr-TR"
    }
  end

  defp platform!(product) do
    attrs = %{
      id: Relay.Id.generate(),
      access_tenant_id: "acc_" <> FakeAccess.random(),
      region: TenantFixture.region(),
      sector: "general",
      default_timezone: "Europe/Istanbul",
      default_locale: "tr-TR",
      record_digest: TenantFixture.digest(),
      product: product
    }

    {:created, id} = Relay.Access.create_platform_tenant(attrs, TenantFixture.actor())
    %{id: id, live: Relay.Scope.new!(id, :live)}
  end

  defp count(scope, sql, params) do
    {:ok, [[n]]} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    n
  end

  defp notification_class(token, workflow) do
    body = %{
      "workflow" => workflow,
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    F.body(F.request(:get, "/v1/notifications/" <> notification, token), 200)["message_class"]
  end

  describe "C-18 E-9 TN-9 platform tenant" do
    test "C-18, E-9, TN-9: tenant.created with a platform product creates its tenant" do
      access_tenant = "acc_" <> FakeAccess.random()
      data = Map.put(tenant_data(access_tenant), "platform_product", "access")
      id = deliver!("tenant.created", data)

      assert receipt_of(id)["state"] == "processed"

      assert %{id: tenant_id, status: "active", platform: "access"} =
               ClientStore.tenant(access_tenant)

      scope = Relay.Scope.new!(tenant_id, :live)
      assert {:ok, purposes} = Relay.Tenancy.active_key_purposes(scope)
      assert :data in purposes

      again = deliver!("tenant.created", data)
      assert receipt_of(again)["state"] == "processed"
    end

    test "TN-9: only a Suiss product becomes a platform tenant" do
      attrs = %{access_tenant_id: "acc_" <> FakeAccess.random(), product: "acme"}

      assert {:error, %Relay.Error{code: :invalid_argument}} =
               Relay.Access.create_platform_tenant(attrs, TenantFixture.actor())
    end

    test "TN-9: a platform tenant holds no data privilege in either direction" do
      platform = platform!("access")
      other = TenantFixture.tenant!()
      platform_recipient = TenantFixture.recipient!(platform.live, nil)
      other_recipient = TenantFixture.recipient!(other.live, nil)
      sql = "SELECT count(*) FROM relay.recipients WHERE id = $1"

      assert count(platform.live, sql, [platform_recipient]) == 1
      assert count(platform.live, sql, [other_recipient]) == 0
      assert count(other.live, sql, [platform_recipient]) == 0
    end
  end

  describe "E-10 E-11 Access semantic events" do
    test "E-11: an Access event is a security message; a class the producer declares wins" do
      platform = platform!("access")
      token = F.token(platform.live)
      F.workflow!(platform.live, token, "session-alert", message_class: "security")
      F.workflow!(platform.live, token, "digest-note", message_class: "operational")

      assert notification_class(token, "session-alert") == "security"
      assert notification_class(token, "digest-note") == "operational"
      assert Relay.Access.message_class("access", nil) == :security
      assert Relay.Access.message_class("work", nil) == nil
    end
  end
end
