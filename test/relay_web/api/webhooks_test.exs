defmodule RelayWeb.Api.WebhooksTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @url "https://hooks.example.com/relay"

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp post(ctx, path, body, status), do: F.body(F.request(:post, path, ctx.token, body), status)
  defp patch(ctx, path, body, status),
    do: F.body(F.request(:patch, path, ctx.token, body), status)

  defp get(ctx, path, status \\ 200), do: F.body(F.request(:get, path, ctx.token), status)

  defp put(ctx, emails),
    do: F.request(:put, "/v1/operations_contacts", ctx.token, %{"emails" => emails})

  defp cursor(ctx, path), do: get(ctx, path <> "/versions?limit=1")["next_cursor"]

  defp endpoint(overrides \\ %{}) do
    Map.merge(
      %{
        "use" => "relay_events",
        "destination" => %{"kind" => "https", "url" => @url},
        "event_types" => ["notification.delivered"]
      },
      overrides
    )
  end

  defp endpoint!(ctx, overrides \\ %{}),
    do: post(ctx, "/v1/webhook_endpoints", endpoint(overrides), 201)

  defp consumer!(ctx, key \\ nil) do
    key = key || "shop-" <> TenantFixture.random()
    post(ctx, "/v1/webhook_consumers", %{"key" => key, "source" => "urn:shop:" <> key}, 201)
  end

  defp event_type!(ctx, name \\ "order.shipped") do
    body = %{
      "name" => name,
      "schema" => %{
        "type" => "object",
        "required" => ["order_id"],
        "properties" => %{"order_id" => %{"type" => "string"}, "note" => %{"type" => "string"}}
      },
      "identifiers" => ["order_id"],
      "example" => %{"order_id" => "A-1"}
    }

    post(ctx, "/v1/webhook_event_types", body, 201)
  end

  defp id!(text, prefix) do
    {:ok, id} = Relay.ExternalId.decode(text, [prefix])
    id
  end

  defp header!(ctx, endpoint, webhook_id, timestamp, body) do
    {:ok, keys} = Relay.Webhooks.signing_keys(ctx.scope, id!(endpoint["id"], "whe"))
    {:ok, header} = Relay.Webhooks.sign(ctx.scope, keys, webhook_id, timestamp, body)
    header
  end

  defp public!("whpk_" <> encoded), do: Base.decode64!(encoded)

  defp audit(scope, action) do
    now = DateTime.utc_now()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
        )
      end)

    for row <- rows, do: Map.take(row, ~w(actor_kind target_type target_id))
  end

  describe "WH-2 WH-45 endpoints" do
    test "WH-2, WH-45, INV-39: an endpoint belongs to the environment of the credential and never to one the request names",
         ctx do
      created = endpoint!(ctx)

      assert %{
               "object" => "webhook_endpoint",
               "environment" => "live",
               "use" => "relay_events",
               "consumer" => nil,
               "state" => "active",
               "managed_by" => "tenant",
               "auto_disable" => true,
               "retry_schedule" => nil,
               "version" => 1,
               "destination" => %{"kind" => "https", "url" => @url}
             } = created

      assert "whe_" <> _ = created["id"]
      path = "/v1/webhook_endpoints/" <> created["id"]
      assert get(ctx, path)["id"] == created["id"]

      refused = post(ctx, "/v1/webhook_endpoints", endpoint(%{"environment" => "test"}), 422)
      assert refused["code"] == "unknown_field"

      patched = F.request(:patch, path, ctx.token, %{"environment" => "test"})
      assert F.body(patched, 422)["code"] == "unknown_field"

      other = F.request(:get, path, F.token(ctx.tenant.test))
      assert F.body(other, 404)["code"] == "webhook_endpoint_not_found"

      listed = get(ctx, "/v1/webhook_endpoints?use=relay_events&state=active")
      assert Enum.map(listed["data"], & &1["id"]) == [created["id"]]
      assert get(ctx, "/v1/webhook_endpoints?state=archived")["data"] == []
    end

    test "WH-48: creating and archiving an endpoint are audited and nothing is deleted", ctx do
      created = endpoint!(ctx)
      path = "/v1/webhook_endpoints/" <> created["id"]
      archived = post(ctx, path <> "/archive", nil, 200)

      assert %{"state" => "archived", "signing_keys" => []} = archived
      assert archived["archived_at"]
      assert post(ctx, path <> "/archive", nil, 200)["state"] == "archived"
      assert get(ctx, path)["state"] == "archived"

      assert patch(ctx, path, %{"description" => "late"}, 422)["code"] ==
               "webhook_endpoint_archived"

      target = Relay.Id.to_string(id!(created["id"], "whe"))

      for action <- ["webhook_endpoint.created", "webhook_endpoint.archived"] do
        assert [%{"actor_kind" => "api_client", "target_type" => "webhook_endpoint"}] =
                 Enum.filter(audit(ctx.scope, action), &(&1["target_id"] == target))
      end
    end
  end

  describe "WH-4 WH-5 WH-6 signing keys" do
    test "WH-4, WH-5, TN-32: a v1a endpoint has its own Ed25519 key, its public key is readable and its signature is over id.timestamp.body",
         ctx do
      created = endpoint!(ctx)
      assert created["signature_scheme"] == "v1a"
      assert created["secret"] == nil

      assert [%{"scheme" => "v1a", "state" => "active", "expires_at" => nil} = key] =
               created["signing_keys"]

      assert "whk_" <> _ = key["id"]
      public = public!(key["public_key"])
      assert byte_size(public) == 32

      body = ~s({"specversion":"1.0","id":"evt_1"})
      assert "v1a," <> encoded = header!(ctx, created, "evt_1", 1_700_000_000, body)
      signature = Base.decode64!(encoded)
      content = "evt_1.1700000000." <> body
      assert :crypto.verify(:eddsa, :none, content, signature, [public, :ed25519])
      refute :crypto.verify(:eddsa, :none, content <> " ", signature, [public, :ed25519])

      other = endpoint!(ctx)
      [other_key] = other["signing_keys"]
      refute other_key["public_key"] == key["public_key"]
      read = get(ctx, "/v1/webhook_endpoints/" <> created["id"])
      assert [%{"public_key" => same}] = read["signing_keys"]
      assert same == key["public_key"]
    end

    test "WH-5, TN-35: a v1 secret is shown once and signs with HMAC-SHA256", ctx do
      created = endpoint!(ctx, %{"signature_scheme" => "v1"})
      assert "whsec_" <> encoded = created["secret"]
      secret = Base.decode64!(encoded)
      assert byte_size(secret) == 32
      assert [%{"scheme" => "v1", "public_key" => nil}] = created["signing_keys"]

      read = get(ctx, "/v1/webhook_endpoints/" <> created["id"])
      refute Map.has_key?(read, "secret")
      refute Jason.encode!(read) =~ encoded

      assert "v1," <> mac = header!(ctx, created, "evt_2", 1_700_000_001, "{}")
      assert Base.decode64!(mac) == :crypto.mac(:hmac, :sha256, secret, "evt_2.1700000001.{}")

      {:ok, [stored]} = Relay.Webhooks.signing_keys(ctx.scope, id!(created["id"], "whe"))
      refute stored["secret_ct"] =~ secret
    end

    test "WH-6, WH-48: a rotation overlaps, both keys sign with the new one first, and it is audited",
         ctx do
      created = endpoint!(ctx)
      path = "/v1/webhook_endpoints/" <> created["id"]
      [%{"public_key" => old_public, "id" => old_id}] = created["signing_keys"]

      rotated = post(ctx, path <> "/rotate_key", nil, 200)
      assert rotated["secret"] == nil
      {:ok, expires_at, 0} = DateTime.from_iso8601(rotated["previous_key_expires_at"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 86_400, 120

      assert [
               %{"state" => "active", "public_key" => new_public},
               %{"state" => "previous", "id" => ^old_id, "public_key" => ^old_public}
             ] = rotated["signing_keys"]

      refute new_public == old_public
      assert [first, second] = String.split(header!(ctx, created, "evt_3", 5, "{}"), " ")
      content = "evt_3.5.{}"

      for {"v1a," <> encoded, public} <- [{first, new_public}, {second, old_public}] do
        assert :crypto.verify(:eddsa, :none, content, Base.decode64!(encoded), [
                 public!(public),
                 :ed25519
               ])
      end

      at_once = %{"overlap" => "PT0S", "signature_scheme" => "v1"}
      now = post(ctx, path <> "/rotate_key", at_once, 200)
      assert "whsec_" <> _ = now["secret"]
      assert now["previous_key_expires_at"] == nil
      assert [%{"scheme" => "v1", "state" => "active"}] = now["signing_keys"]
      assert now["signature_scheme"] == "v1"
      assert "v1," <> _ = header!(ctx, created, "evt_4", 6, "{}")

      long = post(ctx, path <> "/rotate_key", %{"overlap" => "P8D"}, 422)
      assert [%{"pointer" => "/overlap"}] = long["errors"]

      target = Relay.Id.to_string(id!(created["id"], "whe"))
      rotations = audit(ctx.scope, "webhook_endpoint.key_rotated")
      assert length(Enum.filter(rotations, &(&1["target_id"] == target))) == 2
    end
  end

  describe "WH-16 WH-52 subscription and limits" do
    test "WH-16, WH-53: the subscription is an explicit selection of catalog types, * or nothing",
         ctx do
      assert endpoint!(ctx, %{"event_types" => []})["event_types"] == []
      assert endpoint!(ctx, %{"event_types" => ["*"]})["event_types"] == ["*"]

      unknown = endpoint(%{"event_types" => ["notification.delivered", "order.shipped"]})
      refused = post(ctx, "/v1/webhook_endpoints", unknown, 422)
      assert refused["code"] == "validation_failed"
      assert [%{"pointer" => "/event_types/1", "code" => "not_found"}] = refused["errors"]

      for name <- ~w(email.bounced consent.rejected export.completed webhook_endpoint.tested) do
        assert Relay.EventCatalog.delivered?(name), name
      end

      refute Relay.EventCatalog.delivered?("inbox.item_created")
    end

    test "WH-16, WH-52: a tenant has at most 20 endpoints of its own and a consumer at most 5; archived ones do not count",
         ctx do
      %{per_tenant: 20, per_consumer: 5} = Relay.Webhooks.endpoint_limits()
      own = for _n <- 1..20, do: endpoint!(ctx)["id"]

      assert post(ctx, "/v1/webhook_endpoints", endpoint(), 422)["code"] ==
               "webhook_endpoint_limit_reached"

      post(ctx, "/v1/webhook_endpoints/#{hd(own)}/archive", nil, 200)
      endpoint!(ctx)

      event_type!(ctx)
      consumer = consumer!(ctx)
      body = %{"use" => "destination", "consumer" => consumer["key"], "event_types" => ["*"]}
      for _n <- 1..5, do: endpoint!(ctx, body)

      assert post(ctx, "/v1/webhook_endpoints", endpoint(body), 422)["code"] ==
               "webhook_endpoint_limit_reached"

      endpoint!(ctx, Map.put(body, "consumer", consumer!(ctx)["key"]))
    end

    test "WH-2, WH-13: a destination endpoint names an existing consumer and the tenant's event types",
         ctx do
      event_type!(ctx)
      consumer = consumer!(ctx)

      body = %{
        "use" => "destination",
        "consumer" => consumer["key"],
        "event_types" => ["order.shipped"]
      }

      created = endpoint!(ctx, body)
      assert created["consumer"] == consumer["key"]
      assert created["consumer_id"] == consumer["id"]

      listed = get(ctx, "/v1/webhook_endpoints?consumer_id=" <> consumer["id"])
      assert Enum.map(listed["data"], & &1["id"]) == [created["id"]]

      for {change, pointer} <- [
            {%{"consumer" => "nobody"}, "/consumer"},
            {%{"event_types" => ["order.cancelled"]}, "/event_types"}
          ] do
        refused = post(ctx, "/v1/webhook_endpoints", endpoint(Map.merge(body, change)), 422)
        assert [%{"pointer" => ^pointer, "code" => "not_found"}] = refused["errors"]
      end

      missing = post(ctx, "/v1/webhook_endpoints", endpoint(%{"use" => "destination"}), 422)
      assert [%{"pointer" => "/consumer", "code" => "required"}] = missing["errors"]

      in_use = post(ctx, "/v1/webhook_consumers/#{consumer["id"]}/archive", nil, 422)
      assert in_use["code"] == "webhook_consumer_in_use"
    end
  end

  describe "WH-40 registration rules" do
    test "WH-40: an address is https, on an allowed port, without user information", ctx do
      for url <- ["https://hooks.example.com:8443/x", "https://user:pass@hooks.example.com/x"] do
        body = endpoint(%{"destination" => %{"kind" => "https", "url" => url}})
        refused = post(ctx, "/v1/webhook_endpoints", body, 422)
        assert refused["code"] == "webhook_endpoint_url_not_allowed"
        assert [%{"pointer" => "/destination/url", "code" => "not_allowed"}] = refused["errors"]
      end

      insecure = %{"kind" => "https", "url" => "http://hooks.example.com"}
      plain = endpoint(%{"destination" => insecure})
      assert post(ctx, "/v1/webhook_endpoints", plain, 422)["code"] == "validation_failed"

      created = endpoint!(ctx)
      path = "/v1/webhook_endpoints/" <> created["id"]
      moved = %{"destination" => %{"kind" => "https", "url" => "https://hooks.example.com:444/"}}
      assert patch(ctx, path, moved, 422)["code"] == "webhook_endpoint_url_not_allowed"

      other_kind = %{"destination" => %{"kind" => "s3", "bucket" => "events", "region" => "eu"}}
      assert patch(ctx, path, other_kind, 422)["code"] in ["validation_failed", "unknown_field"]
    end

    test "WH-40 (2): the installation allows more ports; a tenant cannot" do
      refused = {:error, :port_not_allowed}
      assert Relay.Webhooks.allowed_ports() == [443]
      assert Relay.Webhooks.check_address("https://a.example:8443/") == refused
      previous = Application.get_env(:relay, Relay.Webhooks)
      Application.put_env(:relay, Relay.Webhooks, extra_ports: [8443])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:relay, Relay.Webhooks, previous),
          else: Application.delete_env(:relay, Relay.Webhooks)
      end)

      assert Relay.Webhooks.allowed_ports() == [443, 8443]
      assert Relay.Webhooks.check_address("https://a.example:8443/") == :ok
      assert Relay.Webhooks.check_address("https://a.example/") == :ok
      assert Relay.Webhooks.check_address("https://a.example:444/") == refused
      assert Relay.Webhooks.check_address("http://a.example/") == {:error, :not_https}
      assert Relay.Webhooks.check_address("https://u@a.example/") == {:error, :user_information}
      assert Relay.Webhooks.check_address("https:///path") == {:error, :no_host}
    end
  end

  describe "WH-12 WH-22 WH-36 endpoint settings" do
    test "WH-12, API-55: the snapshot is pinned to the endpoint version and the payload version to the endpoint",
         ctx do
      created = endpoint!(ctx, %{"snapshot" => ["channel"]})
      path = "/v1/webhook_endpoints/" <> created["id"]
      assert created["payload_version"] == Relay.Api.Versions.latest()

      same = patch(ctx, path, %{"description" => "orders"}, 200)
      assert %{"version" => 1, "description" => "orders", "snapshot" => ["channel"]} = same

      changed = patch(ctx, path, %{"snapshot" => ["channel", "status"]}, 200)
      assert %{"version" => 2, "snapshot" => ["channel", "status"]} = changed
      assert changed["payload_version"] == created["payload_version"]

      assert %{"snapshot" => ["channel"], "version" => 1} = get(ctx, path <> "/versions/1")
      assert %{"snapshot" => ["channel", "status"]} = get(ctx, path <> "/versions/2")
      assert get(ctx, path <> "/versions/3", 404)["code"] == "webhook_endpoint_not_found"
      assert Enum.map(get(ctx, path <> "/versions")["data"], & &1["version"]) == [2, 1]
      next = path <> "/versions?limit=1&starting_after=" <> cursor(ctx, path)
      assert [%{"version" => 1}] = get(ctx, next)["data"]
    end

    test "WH-22, WH-52, WH-38: a tenant sets the schedule, concurrency and rate within the bounds",
         ctx do
      settings = %{
        "retry_schedule" => ["PT0S", "PT30S", "PT10M"],
        "max_concurrency" => 4,
        "rate_limit_per_second" => 20
      }

      created = endpoint!(ctx, settings)
      assert Map.take(created, Map.keys(settings)) == settings
      path = "/v1/webhook_endpoints/" <> created["id"]
      assert patch(ctx, path, %{"retry_schedule" => nil}, 200)["retry_schedule"] == nil
      assert patch(ctx, path, %{"retry_schedule" => ["PT0S"]}, 200)["retry_schedule"] == ["PT0S"]

      for schedule <- [["PT0S", "PT1S"], ["PT0S", "PT25H"], ["PT0S", "PT10S"], ["PT0S", "P1M"]] do
        refused = patch(ctx, path, %{"retry_schedule" => schedule}, 422)
        assert [%{"pointer" => "/retry_schedule" <> _}] = refused["errors"]
      end

      week = List.duplicate("PT24H", 8)
      refused = post(ctx, "/v1/webhook_endpoints", endpoint(%{"retry_schedule" => week}), 422)
      assert [%{"pointer" => "/retry_schedule"}] = refused["errors"]
    end

    test "WH-36, WH-48: switching the automatic disable off is audited; a disabled endpoint is enabled again",
         ctx do
      created = endpoint!(ctx)
      path = "/v1/webhook_endpoints/" <> created["id"]
      assert patch(ctx, path, %{"auto_disable" => false}, 200)["auto_disable"] == false
      target = Relay.Id.to_string(id!(created["id"], "whe"))

      assert [%{"target_id" => ^target}] =
               audit(ctx.scope, "webhook_endpoint.auto_disable_switched_off")

      disabled = patch(ctx, path, %{"state" => "disabled"}, 200)
      assert %{"state" => "disabled", "disabled_reason" => "manual"} = disabled
      enabled = patch(ctx, path, %{"state" => "active"}, 200)
      assert %{"state" => "active", "disabled_reason" => nil} = enabled

      stale = F.request(:patch, path, ctx.token, %{"description" => "x"}, [{"if-match", ~s("1")}])
      assert F.body(stale, 412)["code"] == "precondition_failed"
    end
  end

  describe "WH-2 consumers" do
    test "WH-2, WH-8: a consumer is created, changed and archived; its key is unique", ctx do
      created = consumer!(ctx, "shop-42")

      assert %{"object" => "webhook_consumer", "key" => "shop-42", "state" => "active"} = created
      assert created["source"] == "urn:shop:shop-42"
      path = "/v1/webhook_consumers/" <> created["id"]
      assert get(ctx, path)["id"] == created["id"]

      conflict = post(ctx, "/v1/webhook_consumers", %{"key" => "shop-42"}, 409)
      assert conflict["code"] == "resource_conflict"

      renamed = patch(ctx, path, %{"name" => "Shop 42", "source" => nil}, 200)
      assert %{"name" => "Shop 42", "source" => nil, "version" => 2} = renamed
      assert Enum.map(get(ctx, "/v1/webhook_consumers")["data"], & &1["id"]) == [created["id"]]

      assert post(ctx, path <> "/archive", nil, 200)["state"] == "archived"
      assert patch(ctx, path, %{"name" => "x"}, 422)["code"] == "webhook_consumer_archived"
      assert get(ctx, "/v1/webhook_consumers?state=active")["data"] == []
      missing = "/v1/webhook_consumers/whc_01j9zq3k4m5n6p7q8r9s0t1v2w"
      assert get(ctx, missing, 404)["code"] == "webhook_consumer_not_found"
    end
  end

  describe "WH-13 WH-14 tenant event types" do
    test "WH-14: an event type has versioned schemas; a schema change opens a new version", ctx do
      created = event_type!(ctx)

      assert %{"object" => "webhook_event_type", "name" => "order.shipped", "version" => 1} =
               created

      assert created["identifiers"] == ["order_id"]
      assert created["example"] == %{"order_id" => "A-1"}
      path = "/v1/webhook_event_types/" <> created["id"]

      again = %{"name" => "order.shipped", "schema" => %{}}
      assert post(ctx, "/v1/webhook_event_types", again, 409)["code"] == "resource_conflict"

      schema = Map.put(created["schema"], "required", ["order_id", "note"])
      next = %{"schema" => schema, "identifiers" => ["order_id"]}
      assert %{"version" => 2, "example" => nil} = post(ctx, path <> "/versions", next, 201)
      assert post(ctx, path <> "/versions", next, 200)["version"] == 2
      assert get(ctx, path)["version"] == 2
      assert get(ctx, path <> "/versions/1")["schema"] == created["schema"]
      assert Enum.map(get(ctx, path <> "/versions")["data"], & &1["version"]) == [2, 1]

      assert post(ctx, path <> "/archive", nil, 200)["state"] == "archived"
      assert post(ctx, path <> "/versions", %{"schema" => %{}}, 422)["code"] ==
               "webhook_event_type_archived"
    end

    test "WH-13: the schema is JSON Schema 2020-12, its identifiers are its properties and its example is valid",
         ctx do
      base = %{"name" => "order.paid", "schema" => %{"type" => "object", "properties" => %{}}}

      for {change, pointer} <- [
            {%{"schema" => %{"$ref" => "#/$defs/missing"}}, "/schema"},
            {%{"schema" => %{"$schema" => "http://json-schema.org/draft-07/schema#"}}, "/schema"},
            {%{"identifiers" => ["order_id"]}, "/identifiers"},
            {%{"schema" => %{"type" => "object", "required" => ["a"]}, "example" => %{}},
             "/example"}
          ] do
        refused = post(ctx, "/v1/webhook_event_types", Map.merge(base, change), 422)
        assert [%{"pointer" => ^pointer}] = refused["errors"], pointer
      end
    end
  end

  describe "WH-56 operations contacts" do
    test "WH-56, WH-48: a tenant has at most five operations contacts, stored sealed and replaced as a whole",
         ctx do
      assert %{"object" => "operations_contacts", "emails" => [], "updated_at" => nil} =
               get(ctx, "/v1/operations_contacts")

      emails = ["ops@example.com", "oncall@example.com"]
      assert F.body(put(ctx, emails), 200)["emails"] == emails
      assert %{"emails" => ^emails, "updated_at" => at} = get(ctx, "/v1/operations_contacts")
      assert at

      {:ok, %{rows: rows}} =
        Relay.Repo.in_scope(ctx.scope, fn _status ->
          Relay.Repo.scoped_query!(
            "SELECT address_ct FROM relay.operations_contacts WHERE state = 'active'",
            []
          )
        end)

      assert length(rows) == 2
      for [ct] <- rows, email <- emails, do: refute(ct =~ email)

      six = for n <- 1..6, do: "ops#{n}@example.com"
      assert F.body(put(ctx, six), 422)["code"] == "validation_failed"
      assert F.body(put(ctx, ["not-an-address"]), 422)["code"] == "validation_failed"
      assert F.body(put(ctx, []), 200)["emails"] == []
      assert get(ctx, "/v1/operations_contacts")["emails"] == []
      assert length(audit(ctx.scope, "operations_contacts.replaced")) == 2

      other = %{ctx | token: F.token(ctx.tenant.test)}
      assert get(other, "/v1/operations_contacts")["emails"] == []
    end
  end
end
