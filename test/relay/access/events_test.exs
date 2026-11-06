defmodule Relay.Access.EventsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.ClientStore
  alias Relay.Access.Events
  alias Relay.Api.Schema
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture

  defmodule Handler do
    @moduledoc false
    @behaviour Relay.Access.UserHandler

    @impl Relay.Access.UserHandler
    def handle_user_event(kind, subject, event_ref) do
      send(Application.fetch_env!(:relay, :access_events_test), {:user, kind, subject, event_ref})
      :ok
    end
  end

  setup do
    :ok = FakeAccess.install!()
    :ok
  end

  defp deliver!(type, data) do
    claims = FakeAccess.event(type, data)
    conn = FakeAccess.deliver(claims)
    assert conn.status == 202
    assert conn.resp_body == ""
    claims["jti"]
  end

  defp refused(conn) do
    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    schema = Schema.response_schema("receiveAccessEvent", "400", "application/json")
    assert :ok == Schema.validate(Schema.build(schema), body)
    body["err"]
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

  defp subtenant(scope, organization),
    do: ClientStore.in_scope(scope, fn _status -> ClientStore.subtenant(organization) end)

  defp verify(token), do: Relay.Access.verify_server_token(token, FakeAccess.presented(token))

  defp jobs do
    sql = "SELECT count(*) FROM relay_queue.oban_jobs WHERE worker = 'Relay.Access.EventConsumer'"
    [[count]] = Relay.Repo.query!(sql, []).rows
    count
  end

  describe "E-94 intake" do
    test "E-94, S-69: a signed SET is recorded with its job before 202 and a repeat is not queued again" do
      token = FakeAccess.set(FakeAccess.event("user.reactivated", %{"subject" => "pairwise-1"}))

      assert FakeAccess.deliver(token).status == 202
      assert jobs() == 1
      assert FakeAccess.deliver(token).status == 202
      assert jobs() == 1
    end

    test "E-94: a forged, stale, foreign or misaddressed SET is refused with its RFC 8935 code and records nothing" do
      claims = FakeAccess.event("user.reactivated", %{"subject" => "pairwise-1"})
      [header, payload, _signature] = String.split(FakeAccess.set(claims), ".")
      forged = header <> "." <> payload <> "." <> Base.url_encode64(<<0::512>>, padding: false)

      for {token, err} <- [
            {forged, "authentication_failed"},
            {FakeAccess.set(%{claims | "iat" => 1_700_000_000}), "invalid_request"},
            {FakeAccess.set(%{claims | "iss" => "https://other.test"}), "invalid_issuer"},
            {FakeAccess.set(%{claims | "aud" => "app_other"}), "invalid_audience"},
            {FakeAccess.set(claims, %{"typ" => "JWT"}), "invalid_request"},
            {"not a set", "invalid_request"}
          ] do
        assert refused(FakeAccess.deliver(token)) == err
      end

      assert FakeAccess.deliver(claims, content_type: "application/json").status == 415
      assert jobs() == 0
    end

    test "E-94: a SET of an Access event type that is not an event name of Relay's form is acknowledged and not recorded" do
      claims = FakeAccess.event("authority-revoked", %{"domain" => "d"})

      assert FakeAccess.deliver(claims).status == 202
      assert jobs() == 0
    end

    test "E-70: only the mapping fields of a consumed type cross the boundary; another type keeps none" do
      data = %{"subject" => "pairwise-1", "email" => "user@example.com"}
      assert Events.minimal("user.suspended", data) == %{"subject" => "pairwise-1"}
      assert Events.minimal("consent.granted", %{"phone" => "+905551112233"}) == %{}

      id = deliver!("consent.granted", %{"phone" => "+905551112233"})
      receipt = receipt_of(id)
      assert receipt["state"] == "rejected"
      assert receipt["payload"] == %{}
      assert receipt["event_type"] == "consent.granted"
    end
  end

  describe "TN-1 TN-6 mapping" do
    test "TN-1, TN-2, X-35, INV-41: tenant.created creates the mapped tenant; missing defaults or another region are rejected" do
      access_tenant = "acc_" <> FakeAccess.random()
      id = deliver!("tenant.created", tenant_data(access_tenant))

      assert receipt_of(id)["state"] == "processed"
      assert %{id: tenant_id, status: "active", platform: nil} = ClientStore.tenant(access_tenant)
      scope = Relay.Scope.new!(tenant_id, :test)
      assert {:ok, purposes} = Relay.Tenancy.active_key_purposes(scope)
      assert :blind_index in purposes

      no_locale = Map.delete(tenant_data("acc_" <> FakeAccess.random()), "default_locale")
      missing = deliver!("tenant.created", no_locale)
      assert %{"state" => "rejected", "reason" => "defaults_missing"} = receipt_of(missing)

      region = Enum.find(["tr", "eu", "us"], &(&1 != FakeAccess.installation_region()))
      elsewhere = %{tenant_data("acc_" <> FakeAccess.random()) | "region" => region}
      other = deliver!("tenant.created", elsewhere)
      assert %{"state" => "rejected", "reason" => "region_mismatch"} = receipt_of(other)
    end

    test "E-94, E-80: Access's member names and the access_tenant claim map onto the same event" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = %{"organization" => "org_8", "name" => "Brand"}
      event = FakeAccess.event("organization.created", member)
      claims = Map.put(event, "access_tenant", access_tenant)

      assert FakeAccess.deliver(claims).status == 202
      assert receipt_of(claims["jti"])["state"] == "processed"
      assert {:ok, %{name: "Brand"}} = subtenant(tenant.live, "org_8")
    end

    test "TN-6, C-12: organization events map to one sub-tenant in both environments and archive it" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      organization = %{"access_tenant_id" => access_tenant, "access_organization_id" => "org_7"}

      created = deliver!("organization.created", Map.put(organization, "name", "Shop"))
      assert receipt_of(created)["state"] == "processed"

      [live, test] =
        for scope <- [tenant.live, tenant.test] do
          {:ok, subtenant} = subtenant(scope, "org_7")
          subtenant
        end

      assert live.id == test.id
      assert live.name == "Shop" and live.state == "active"

      archived = deliver!("organization.updated", Map.put(organization, "state", "archived"))
      assert receipt_of(archived)["state"] == "processed"

      for scope <- [tenant.live, tenant.test] do
        assert {:ok, %{state: "archived"}} = subtenant(scope, "org_7")
      end
    end
  end

  describe "API-44 TN-24 API clients" do
    test "API-44, TN-24, TN-36: api_client events write the trace and a revocation is rejected at once" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      client = %{"access_tenant_id" => access_tenant, "access_client_id" => "app_events"}

      live = Map.merge(client, %{"environment" => "live", "scopes" => ["publish"]})
      created = deliver!("api_client.created", live)

      assert receipt_of(created)["state"] == "processed"
      token = FakeAccess.server_token(access_tenant, "app_events", "publish read")
      assert {:ok, %{scope: scope, scopes: ["publish"]}} = verify(token)
      assert scope == tenant.live

      updated = deliver!("api_client.updated", Map.put(client, "scopes", ["publish", "read"]))
      assert receipt_of(updated)["state"] == "processed"
      assert {:ok, %{scopes: ["publish", "read"]}} = verify(token)

      revoked = deliver!("api_client.revoked", client)
      assert receipt_of(revoked)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      again = deliver!("api_client.reactivated", client)
      assert receipt_of(again)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)
    end

    test "E-97: api_client.disabled suspends the client and api_client.reactivated opens it again" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      client = %{"access_tenant_id" => access_tenant, "access_client_id" => "app_retired"}
      live = Map.merge(client, %{"environment" => "live", "scopes" => ["publish"]})
      assert receipt_of(deliver!("api_client.created", live))["state"] == "processed"

      token = FakeAccess.server_token(access_tenant, "app_retired", "publish")
      assert {:ok, %{scopes: ["publish"]}} = verify(token)

      member = %{
        "tenant" => access_tenant,
        "realm" => "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b10",
        "client_id" => "app_retired",
        "exercise" => String.duplicate("A", 43),
        "at" => 1_790_000_000_000
      }

      disabled = deliver!("api_client.disabled", member)
      assert receipt_of(disabled)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      again = deliver!("api_client.reactivated", client)
      assert receipt_of(again)["state"] == "processed"
      assert {:ok, %{scopes: ["publish"]}} = verify(token)
    end

    test "API-44: an event for a tenant or sub-tenant that does not exist yet waits and applies once it does" do
      access_tenant = "acc_" <> FakeAccess.random()

      client = %{
        "access_tenant_id" => access_tenant,
        "access_client_id" => "app_waiting",
        "environment" => "test",
        "access_organization_id" => "org_9",
        "scopes" => ["read"]
      }

      waiting = deliver!("api_client.created", client)
      assert %{"state" => "deferred", "reason" => "unknown_tenant"} = receipt_of(waiting)

      deliver!("tenant.created", tenant_data(access_tenant))
      assert %{"state" => "deferred", "reason" => "subtenant_not_found"} = receipt_of(waiting)

      organization = %{
        "access_tenant_id" => access_tenant,
        "access_organization_id" => "org_9",
        "name" => "B2B"
      }

      deliver!("organization.created", organization)
      assert receipt_of(waiting)["state"] == "processed"

      token = FakeAccess.server_token(access_tenant, "app_waiting", "read")
      assert {:ok, %{subtenant_id: <<_::128>>, scopes: ["read"]}} = verify(token)
    end

    test "API-75: an api_client event with scopes outside API-75 is rejected" do
      tenant = TenantFixture.tenant!()

      client = %{
        "access_tenant_id" => tenant.attrs.access_tenant_id,
        "access_client_id" => "app_admin",
        "environment" => "live",
        "scopes" => ["admin"]
      }

      assert %{"state" => "rejected", "reason" => "invalid_scopes"} =
               receipt_of(deliver!("api_client.created", client))
    end
  end

  describe "TN-20 user events" do
    test "TN-20: a user event waits for a handler and reaches it once one is configured" do
      previous = Application.get_env(:relay, Relay.Access)
      Application.put_env(:relay, Relay.Access, Keyword.put(previous, :user_handlers, []))
      id = deliver!("user.suspended", %{"subject" => "pairwise-op"})
      assert %{"state" => "deferred", "reason" => "no_handler"} = receipt_of(id)

      Application.put_env(:relay, Relay.Access, Keyword.put(previous, :user_handlers, [Handler]))
      Application.put_env(:relay, :access_events_test, self())

      try do
        :ok = Relay.Access.requeue_deferred(nil, "no_handler")
        assert receipt_of(id)["state"] == "processed"
        assert_received {:user, :suspended, "pairwise-op", ^id}
      after
        Application.put_env(:relay, Relay.Access, previous)
        Application.delete_env(:relay, :access_events_test)
      end
    end
  end
end
