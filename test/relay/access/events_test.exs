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
    :ok = TenantFixture.region_defaults!()
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

  defp tenant_member(access_tenant_id),
    do: %{"tenant" => access_tenant_id, "placement" => "pool-default", "at" => 1_790_000_000_000}

  defp client_member(access_tenant_id, client_id) do
    %{
      "tenant" => access_tenant_id,
      "realm" => "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b10",
      "client_id" => client_id,
      "exercise" => String.duplicate("A", 43),
      "at" => 1_790_000_000_000
    }
  end

  defp region_defaults do
    "priv/datasets/region_defaults/v1.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("regions")
    |> Enum.find(&(&1["region"] == FakeAccess.installation_region()))
  end

  defp actor, do: TenantFixture.actor()

  defp assign!(scope, client_id, scopes) do
    assert {:ok, ^client_id} = Relay.Access.assign_api_client(scope, client_id, scopes, actor())
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

  describe "TN-1 E-95 tenants and organizations" do
    test "TN-1, TN-2, E-95: tenant.created opens the tenant in the installation region with that region's defaults" do
      access_tenant = "acc_" <> FakeAccess.random()
      id = deliver!("tenant.created", tenant_member(access_tenant))

      assert receipt_of(id)["state"] == "processed"
      assert %{id: tenant_id, status: "active", platform: nil} = ClientStore.tenant(access_tenant)
      scope = Relay.Scope.new!(tenant_id, :test)
      assert {:ok, purposes} = Relay.Tenancy.active_key_purposes(scope)
      assert :blind_index in purposes

      defaults = region_defaults()
      assert {:ok, tenant} = Relay.Tenancy.tenant(scope)
      assert tenant["region"] == FakeAccess.installation_region()
      assert tenant["default_timezone"] == defaults["time_zone"]
      assert tenant["default_locale"] == defaults["locale"]

      assert receipt_of(deliver!("tenant.created", tenant_member(access_tenant)))["state"] ==
               "processed"

      missing = deliver!("tenant.created", %{"placement" => "pool-default"})
      assert %{"state" => "rejected", "reason" => "tenant_missing"} = receipt_of(missing)
    end

    test "E-95, E-70: the receipt keeps the placement and drops what Relay does not consume" do
      access_tenant = "acc_" <> FakeAccess.random()
      member = Map.put(tenant_member(access_tenant), "owner", "user-1")
      receipt = receipt_of(deliver!("tenant.created", member))

      assert receipt["payload"] == %{
               "access_tenant_id" => access_tenant,
               "placement" => "pool-default"
             }
    end

    test "E-94, E-80, E-95: an organization event with Access's member names is recorded and not applied" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = %{"organization" => "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b11", "at" => 1}
      event = FakeAccess.event("organization.created", member)
      claims = Map.put(event, "access_tenant", access_tenant)

      assert FakeAccess.deliver(claims).status == 202
      receipt = receipt_of(claims["jti"])
      assert %{"state" => "processed", "reason" => "not_applied"} = receipt

      assert receipt["payload"] == %{
               "access_tenant_id" => access_tenant,
               "access_organization_id" => "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b11"
             }

      updated =
        deliver!("organization.updated", %{
          "tenant" => access_tenant,
          "organization" => "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b11",
          "at" => 2
        })

      assert %{"state" => "processed", "reason" => "not_applied"} = receipt_of(updated)

      for scope <- [tenant.live, tenant.test] do
        assert {:ok, nil} = subtenant(scope, "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b11")
      end
    end
  end

  describe "API-44 E-99 API clients" do
    test "E-99: api_client.created registers a pending client whose tokens are refused until it is assigned" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id

      created = deliver!("api_client.created", client_member(access_tenant, "app_events"))
      assert receipt_of(created)["state"] == "processed"

      assert {:ok, [%{access_client_id: "app_events"}]} =
               Relay.Access.pending_api_clients(tenant.id)

      token = FakeAccess.server_token(access_tenant, "app_events", "publish read")
      assert {:error, %Relay.Error{code: :auth_client_pending}} = verify(token)

      again = deliver!("api_client.created", client_member(access_tenant, "app_events"))
      assert receipt_of(again)["state"] == "processed"

      assign!(tenant.live, "app_events", ["publish"])
      assert {:ok, %{scope: scope, scopes: ["publish"]}} = verify(token)
      assert scope == tenant.live
      assert {:ok, []} = Relay.Access.pending_api_clients(tenant.id)
    end

    test "API-44, TN-24, TN-36, E-99: api_client.updated changes nothing and a revocation is rejected at once" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = client_member(access_tenant, "app_status")

      assert receipt_of(deliver!("api_client.created", member))["state"] == "processed"
      assign!(tenant.test, "app_status", ["publish", "read"])
      token = FakeAccess.server_token(access_tenant, "app_status", "publish read")
      assert {:ok, %{scope: scope, scopes: ["publish", "read"]}} = verify(token)
      assert scope == tenant.test

      updated = deliver!("api_client.updated", member)
      assert %{"state" => "processed", "reason" => "not_applied"} = receipt_of(updated)
      assert {:ok, %{scopes: ["publish", "read"]}} = verify(token)

      revoked = deliver!("api_client.revoked", member)
      assert receipt_of(revoked)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      again = deliver!("api_client.reactivated", member)
      assert receipt_of(again)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)
    end

    test "E-97: api_client.disabled suspends the client and api_client.reactivated opens it again" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = client_member(access_tenant, "app_retired")

      assert receipt_of(deliver!("api_client.created", member))["state"] == "processed"
      assign!(tenant.live, "app_retired", ["publish"])
      token = FakeAccess.server_token(access_tenant, "app_retired", "publish")
      assert {:ok, %{scopes: ["publish"]}} = verify(token)

      disabled = deliver!("api_client.disabled", member)
      assert receipt_of(disabled)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      again = deliver!("api_client.reactivated", member)
      assert receipt_of(again)["state"] == "processed"
      assert {:ok, %{scopes: ["publish"]}} = verify(token)
    end

    test "E-99, E-97: a status event of a pending client waits and applies once the client is assigned" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = client_member(access_tenant, "app_early")

      assert receipt_of(deliver!("api_client.created", member))["state"] == "processed"
      disabled = deliver!("api_client.disabled", member)
      assert %{"state" => "deferred", "reason" => "unknown_client"} = receipt_of(disabled)

      assign!(tenant.live, "app_early", ["read"])
      assert receipt_of(disabled)["state"] == "processed"
      token = FakeAccess.server_token(access_tenant, "app_early", "read")
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)
    end

    test "E-99: a client assigned to one environment cannot be assigned to the other" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      deliver!("api_client.created", client_member(access_tenant, "app_once"))
      FakeAccess.drain!()

      assign!(tenant.live, "app_once", ["publish"])
      assign!(tenant.live, "app_once", ["publish", "config"])

      assert {:error, %Relay.Error{code: :resource_conflict}} =
               Relay.Access.assign_api_client(tenant.test, "app_once", ["read"], actor())

      assert {:error, %Relay.Error{code: :api_client_not_found}} =
               Relay.Access.assign_api_client(tenant.live, "app_unknown", ["read"], actor())

      token = FakeAccess.server_token(access_tenant, "app_once", "publish config")
      assert {:ok, %{scope: scope, scopes: scopes}} = verify(token)
      assert scope == tenant.live
      assert Enum.sort(scopes) == ["config", "publish"]
    end

    test "API-44, E-99: an api_client event for a tenant that does not exist yet waits and applies once it does" do
      access_tenant = "acc_" <> FakeAccess.random()

      waiting = deliver!("api_client.created", client_member(access_tenant, "app_waiting"))
      assert %{"state" => "deferred", "reason" => "unknown_tenant"} = receipt_of(waiting)

      deliver!("tenant.created", tenant_member(access_tenant))
      assert receipt_of(waiting)["state"] == "processed"

      %{id: tenant_id} = ClientStore.tenant(access_tenant)

      assert {:ok, [%{access_client_id: "app_waiting"}]} =
               Relay.Access.pending_api_clients(tenant_id)
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
