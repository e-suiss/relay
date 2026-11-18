defmodule Relay.Access.EventsTest do
  use Relay.DataCase, async: false

  alias Relay.Access.ClientStore
  alias Relay.Access.Events
  alias Relay.Access.Pairing.Streams
  alias Relay.Api.Schema
  alias RelayTest.Api
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

  @environment "0b6e5c1a-6f0e-4a8c-9a51-2d0c3f6e7b10"
  @account "usr_01j9zq3k4m5n6p7q8r9s0t1v2w"
  @events "contracts/asyncapi/events.yaml"
  @awaited ~w(agent.reactivated agent.deleted approval.decided relationship.updated
              consent.updated)

  defp deliver!(type, data), do: deliver_claims!(FakeAccess.event(type, data))

  defp deliver_in!(access_tenant, type, data),
    do: deliver_claims!(Map.put(FakeAccess.event(type, data), "access_tenant", access_tenant))

  defp deliver_claims!(claims) do
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

  defp queued_receipt(webhook_id),
    do: Enum.find(FakeAccess.queued(), &(FakeAccess.receipt(&1)["webhook_id"] == webhook_id))

  defp tenant_member(access_tenant_id),
    do: %{"tenant" => access_tenant_id, "placement" => "pool-default", "at" => 1_790_000_000_000}

  defp account_member(status, extra \\ %{}) do
    Map.merge(
      %{
        "environment" => @environment,
        "account" => @account,
        "status" => status,
        "at" => 1_790_000_000_000,
        "access_position" => %{"pos" => 7, "idx" => 0}
      },
      extra
    )
  end

  defp client_member(access_tenant_id, client_id) do
    %{
      "tenant" => access_tenant_id,
      "environment" => @environment,
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

  defp with_user_handlers(handlers, fun) do
    previous = Application.get_env(:relay, Relay.Access)
    Application.put_env(:relay, Relay.Access, Keyword.put(previous, :user_handlers, handlers))
    Application.put_env(:relay, :access_events_test, self())

    try do
      fun.()
    after
      Application.put_env(:relay, Relay.Access, previous)
      Application.delete_env(:relay, :access_events_test)
    end
  end

  defp capture_unresolved do
    test = self()
    id = {__MODULE__, make_ref()}
    event = [:relay, :access, :event, :unresolved]

    handler = fn _event, measurements, meta, _config ->
      send(test, {:unresolved, measurements, meta})
    end

    :ok = :telemetry.attach(id, event, handler, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp message_names(retired?) do
    doc = YamlElixir.read_from_file!(@events)
    messages = doc["components"]["messages"]

    for {_key, %{"$ref" => "#/components/messages/" <> key}} <-
          doc["channels"]["accessInbound"]["messages"],
        Map.get(messages[key], "x-relay-retired", false) == retired?,
        do: messages[key]["name"]
  end

  defp jobs do
    sql = "SELECT count(*) FROM relay_queue.oban_jobs WHERE worker = 'Relay.Access.EventConsumer'"
    [[count]] = Relay.Repo.query!(sql, []).rows
    count
  end

  describe "E-94 intake" do
    test "E-94, S-69: a signed SET is recorded with its job before 202 and a repeat is not queued again" do
      token = FakeAccess.set(FakeAccess.event("account.reactivated", account_member("active")))

      assert FakeAccess.deliver(token).status == 202
      assert jobs() == 1
      assert FakeAccess.deliver(token).status == 202
      assert jobs() == 1
    end

    test "WH-51, WH-49, E-94: a replayed event identifier is counted on its receipt and not processed again" do
      with_user_handlers([Handler], fn ->
        member = account_member("suspended", %{"sub" => "pairwise-7"})
        claims = FakeAccess.event("account.suspended", member)
        jti = claims["jti"]
        token = FakeAccess.set(claims)

        assert FakeAccess.deliver(token).status == 202
        assert %{"state" => "processed", "duplicate_count" => 0} = receipt_of(jti)
        assert_received {:user, :suspended, "pairwise-7", ^jti}

        assert FakeAccess.deliver(token).status == 202
        assert FakeAccess.deliver(token).status == 202
        assert jobs() == 1
        assert %{"state" => "processed", "duplicate_count" => 2} = receipt_of(jti)
        refute_received {:user, :suspended, "pairwise-7", ^jti}
      end)
    end

    test "WH-51, WH-6, E-94: during an overlapping key rotation an event signed with either published key is accepted" do
      kids = Enum.map(FakeAccess.jwks()["keys"], & &1["kid"])
      assert "fake-es256" in kids and "fake-ed25519" in kids

      newer = FakeAccess.event("account.reactivated", account_member("active"))
      older = FakeAccess.event("account.reactivated", account_member("active"))

      assert FakeAccess.deliver(FakeAccess.set(newer)).status == 202

      rotated = FakeAccess.token(older, %{"typ" => "secevent+jwt"})
      assert FakeAccess.deliver(rotated).status == 202
      assert jobs() == 2
    end

    test "WH-51, WH-7, E-94: a tampered token or a stale timestamp is refused with its catalogued error" do
      claims = FakeAccess.event("account.reactivated", account_member("active"))
      [header, _payload, signature] = String.split(FakeAccess.set(claims), ".")
      deleted = %{"urn:suiss:access:event:account.deleted" => account_member("deactivated")}

      tampered =
        %{claims | "events" => deleted}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert refused(FakeAccess.deliver(header <> "." <> tampered <> "." <> signature)) ==
               "authentication_failed"

      stale = %{claims | "iat" => System.system_time(:second) - 306}
      assert refused(FakeAccess.deliver(FakeAccess.set(stale))) == "invalid_request"

      ahead = %{claims | "iat" => System.system_time(:second) + 120}
      assert refused(FakeAccess.deliver(FakeAccess.set(ahead))) == "invalid_request"
      assert jobs() == 0
    end

    test "E-94: a forged, stale, foreign or misaddressed SET is refused with its RFC 8935 code and records nothing" do
      claims = FakeAccess.event("account.reactivated", account_member("active"))
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
      for type <- ["tenant_created", "Tenant.Created", "authority-", "-revoked"] do
        assert FakeAccess.deliver(FakeAccess.event(type, %{"domain" => "d"})).status == 202
      end

      assert jobs() == 0
    end

    test "E-70, E-104: only the mapping fields of a consumed type cross the boundary; another type keeps none" do
      data = account_member("suspended", %{"sub" => "pairwise-1", "email" => "user@example.com"})
      assert Events.minimal("account.suspended", data) == %{"sub" => "pairwise-1"}
      assert Events.minimal("account.created", data) == %{}
      assert Events.minimal("consent.granted", %{"phone" => "+905551112233"}) == %{}

      id = deliver!("consent.granted", %{"phone" => "+905551112233"})
      receipt = receipt_of(id)
      assert receipt["state"] == "rejected"
      assert receipt["payload"] == %{}
      assert receipt["event_type"] == "consent.granted"
    end
  end

  describe "TN-1 E-95 tenants and organizations" do
    test "TN-1, TN-2, E-95: tenant.created opens the tenant in the region of its snapshot with that region's defaults" do
      access_tenant = "acc_" <> FakeAccess.random()
      id = deliver!("tenant.created", tenant_member(access_tenant))

      assert receipt_of(id)["state"] == "processed"
      assert_received {:fake_access, :snapshot, ^access_tenant}
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

    test "E-95, E-70: the receipt keeps the tenant and drops what Relay does not consume" do
      access_tenant = "acc_" <> FakeAccess.random()
      member = Map.put(tenant_member(access_tenant), "owner", "user-1")
      receipt = receipt_of(deliver!("tenant.created", member))

      assert receipt["payload"] == %{"access_tenant_id" => access_tenant}
    end

    test "E-95: while the tenant snapshot cannot be read the event is deferred and retried, and no tenant is opened" do
      for prefix <- ["tnt_down", "tnt_unknown"] do
        access_tenant = prefix <> FakeAccess.random()
        jti = deliver!("tenant.created", tenant_member(access_tenant))
        id = queued_receipt(jti)

        for _attempt <- 1..2 do
          assert {:error, %Relay.Error{}} = Relay.Access.process_event(id)

          assert %{"state" => "deferred", "reason" => "snapshot_unavailable"} =
                   FakeAccess.receipt(id)
        end

        assert ClientStore.tenant(access_tenant) == nil
      end
    end

    test "INV-41, E-39, E-95: a snapshot region this installation does not serve is rejected and no tenant is opened" do
      access_tenant = "tnt_elsewhere" <> FakeAccess.random()
      jti = deliver!("tenant.created", tenant_member(access_tenant))

      assert %{"state" => "rejected", "reason" => "region_mismatch"} = receipt_of(jti)
      assert ClientStore.tenant(access_tenant) == nil
    end

    test "OP-90, INV-41, API-7: a server token of a tenant Access placed in another region is 421 wrong_region and is not forwarded" do
      access_tenant = "tnt_elsewhere" <> FakeAccess.random()
      refute ClientStore.region_refused?(access_tenant)
      jti = deliver!("tenant.created", tenant_member(access_tenant))
      assert %{"state" => "rejected", "reason" => "region_mismatch"} = receipt_of(jti)
      assert ClientStore.region_refused?(access_tenant)

      token = FakeAccess.server_token(access_tenant, "app_" <> FakeAccess.random(), "read")
      path = "/v1/virtual_clock"
      conn = :get |> Api.conn(path, nil, Api.auth(token, :get, path)) |> Api.call()

      assert conn.status == 421
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "wrong_region"
      assert Plug.Conn.get_resp_header(conn, "location") == []

      other = FakeAccess.server_token("tnt_nobody" <> FakeAccess.random(), "app_x", "read")
      conn = :get |> Api.conn(path, nil, Api.auth(other, :get, path)) |> Api.call()
      assert Jason.decode!(conn.resp_body)["code"] == "auth_invalid_token"
    end

    test "E-94, E-80, E-95: an organization event with Access's member names is recorded and not applied" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = %{"organization" => "org_7", "at" => 1}
      event = FakeAccess.event("organization.created", member)
      claims = Map.put(event, "access_tenant", access_tenant)

      assert FakeAccess.deliver(claims).status == 202
      receipt = receipt_of(claims["jti"])
      assert %{"state" => "processed", "reason" => "not_applied"} = receipt

      assert receipt["payload"] == %{
               "access_tenant_id" => access_tenant,
               "access_organization_id" => "org_7"
             }

      updated =
        deliver!("organization.updated", %{
          "tenant" => access_tenant,
          "organization" => "org_7",
          "at" => 2
        })

      assert %{"state" => "processed", "reason" => "not_applied"} = receipt_of(updated)

      for scope <- [tenant.live, tenant.test] do
        assert {:ok, nil} = subtenant(scope, "org_7")
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

    test "API-44, TN-24, TN-36, E-99, E-104: api_client.updated changes nothing and api_client.disabled revokes the client for good" do
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

      disabled = deliver!("api_client.disabled", member)
      assert receipt_of(disabled)["state"] == "processed"
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      for type <- ["api_client.created", "api_client.updated", "api_client.disabled"] do
        assert receipt_of(deliver!(type, member))["state"] == "processed"
      end

      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)

      assert [%{status: "revoked"}] = ClientStore.resolve(access_tenant, "app_status")
    end

    test "E-104, TN-24: the API client statuses Access does not emit are not consumed and change nothing" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      member = client_member(access_tenant, "app_retired")

      assert receipt_of(deliver!("api_client.created", member))["state"] == "processed"
      assign!(tenant.live, "app_retired", ["publish"])
      token = FakeAccess.server_token(access_tenant, "app_retired", "publish")

      for type <- ["api_client.suspended", "api_client.revoked"] do
        receipt = receipt_of(deliver!(type, member))
        assert %{"state" => "rejected", "reason" => "unsupported_type"} = receipt
        assert receipt["payload"] == %{}
      end

      assert {:ok, %{scopes: ["publish"]}} = verify(token)

      assert receipt_of(deliver!("api_client.disabled", member))["state"] == "processed"
      reactivated = receipt_of(deliver!("api_client.reactivated", member))
      assert %{"state" => "rejected", "reason" => "unsupported_type"} = reactivated
      assert {:error, %Relay.Error{code: :auth_revoked_client}} = verify(token)
    end

    test "E-99, E-104: a revocation of a pending client waits and applies once the client is assigned" do
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

  describe "TN-20 E-104 account events" do
    test "TN-20, E-104: an account event that carries a pairwise sub waits for a handler and reaches it once one is configured" do
      member = account_member("suspended", %{"sub" => "pairwise-op"})

      id =
        with_user_handlers([], fn ->
          id = deliver!("account.suspended", member)
          assert %{"state" => "deferred", "reason" => "no_handler"} = receipt_of(id)
          id
        end)

      with_user_handlers([Handler], fn ->
        :ok = Relay.Access.requeue_deferred(nil, "no_handler")
        assert receipt_of(id)["state"] == "processed"
        assert_received {:user, :suspended, "pairwise-op", ^id}
      end)
    end

    test "E-104, TN-20, TN-73: an account event that names the person only by its usr_ id is recorded, not applied, and raises the operator alarm" do
      capture_unresolved()

      with_user_handlers([Handler], fn ->
        for {type, status, kind} <- [
              {"account.suspended", "suspended", :suspended},
              {"account.reactivated", "active", :reactivated},
              {"account.deleted", "deactivated", :deleted}
            ] do
          id = deliver!(type, account_member(status))
          receipt = receipt_of(id)

          assert %{"state" => "processed", "reason" => "not_applied_account_unresolved"} =
                   receipt

          assert receipt["payload"] == %{}
          assert_received {:unresolved, %{count: 1}, %{kind: ^kind}}
          refute_received {:user, _kind, _sub, ^id}
        end
      end)
    end

    test "E-104: the account, session and preference events Relay does not apply are recorded and acknowledged" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      capture_unresolved()

      with_user_handlers([Handler], fn ->
        for {type, member} <- [
              {"account.created", Map.delete(account_member("active"), "status")},
              {"account.updated", account_member("locked")},
              {"session.revoked", Map.put(account_member("active"), "rev", 4)},
              {"preference.changed", Map.put(account_member("active"), "topics", ["news"])}
            ] do
          id = deliver_in!(access_tenant, type, member)
          receipt = receipt_of(id)
          assert %{"state" => "processed", "reason" => "not_applied"} = receipt
          assert receipt["payload"] == %{"access_tenant_id" => access_tenant}
          refute_received {:user, _kind, _sub, ^id}
        end
      end)

      refute_received {:unresolved, _measurements, _meta}
    end

    test "E-104, TN-20: the user events Access never emits are no longer consumed" do
      with_user_handlers([Handler], fn ->
        for type <- ["user.suspended", "user.reactivated", "user.deleted"] do
          id = deliver!(type, %{"subject" => "pairwise-1"})
          receipt = receipt_of(id)
          assert %{"state" => "rejected", "reason" => "unsupported_type"} = receipt
          assert receipt["payload"] == %{}
          refute_received {:user, _kind, _sub, ^id}
        end
      end)
    end
  end

  describe "E-104 Access event names" do
    test "E-104, AG-75: instance-terminated is recorded in Relay's form and not applied; another hyphenated type is unsupported" do
      tenant = TenantFixture.tenant!()
      access_tenant = tenant.attrs.access_tenant_id
      instance = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      member = %{
        "domain" => String.duplicate("A", 43),
        "source" => %{"exercise" => String.duplicate("B", 43)},
        "subject" => %{"kind" => "instance", "id" => instance},
        "party" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "at" => 1_790_000_000_000
      }

      terminated = receipt_of(deliver_in!(access_tenant, "instance-terminated", member))
      assert %{"state" => "processed", "reason" => "not_applied"} = terminated
      assert terminated["event_type"] == "instance.terminated"
      assert terminated["payload"] == %{"access_tenant_id" => access_tenant}

      revoked = receipt_of(deliver_in!(access_tenant, "authority-revoked", member))
      assert %{"state" => "rejected", "reason" => "unsupported_type"} = revoked
      assert revoked["event_type"] == "authority.revoked"
      assert revoked["payload"] == %{}
    end

    test "E-104: the consumed Access events are the messages of the accessInbound contract that are not retired" do
      names = message_names(false)
      assert Enum.sort(names) == Events.types()

      retired = ~w(api_client.reactivated api_client.revoked api_client.suspended user.deleted
                   user.reactivated user.suspended)

      assert Enum.sort(message_names(true)) == retired
      for type <- retired, do: refute(type in names)

      for type <- ~w(account.suspended agent.suspended party.disabled relationship.updated) do
        assert type in names
      end
    end

    test "E-104, E-101: Relay's stream asks for every consumed type Access emits, with Access's URNs, and for no awaited one" do
      catalog = Streams.catalog()

      for type <- Events.types(), type not in @awaited do
        access_name = if type == "instance.terminated", do: "instance-terminated", else: type
        assert ("urn:suiss:access:event:" <> access_name) in catalog, type
      end

      for type <- @awaited, do: refute(("urn:suiss:access:event:" <> type) in catalog, type)

      for urn <- catalog do
        assert "urn:suiss:access:event:" <> name = urn
        assert Regex.match?(~r/\A[a-z][a-z0-9_]*([.-][a-z][a-z0-9_]*)+\z/, name), urn
      end

      assert catalog == Enum.sort(Enum.uniq(catalog))
    end
  end
end
