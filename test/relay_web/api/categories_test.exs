defmodule RelayWeb.Api.CategoriesTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp create(token, body, headers \\ []),
    do: F.request(:post, "/v1/categories", token, body, headers)

  defp category(key, class, extra \\ %{}),
    do: Map.merge(%{"key" => key, "name" => "Name of " <> key, "message_class" => class}, extra)

  defp patch(token, key, body, headers) do
    path = "/v1/categories/" <> key
    auth = Api.auth(token, :patch, path)
    headers = [{"content-type", "application/merge-patch+json"}, F.key() | auth] ++ headers

    :patch
    |> Api.conn(path, Jason.encode!(body), headers)
    |> Api.call(RelayWeb.Router)
  end

  defp etag(token, key),
    do: get_resp_header(F.request(:get, "/v1/categories/" <> key, token), "etag")

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

    for row <- rows, do: Map.take(row, ~w(actor_kind actor_ref target_type target_id))
  end

  describe "PC-57 categories" do
    test "PC-57: create answers 201 with an ETag and the class defaults; the key again is 409",
         ctx do
      conn = create(ctx.token, category("orders", "transactional"))
      body = F.body(conn, 201)

      assert "ctg_" <> _ = body["id"]

      assert %{
               "object" => "category",
               "key" => "orders",
               "message_class" => "transactional",
               "locked" => false,
               "enabled" => true,
               "channel_defaults" => %{},
               "default_expires_in" => nil,
               "frequency" => nil,
               "digest_allowed" => false,
               "state" => "active",
               "builtin" => false,
               "version" => 1,
               "archived_at" => nil
             } = body

      assert get_resp_header(conn, "etag") == [~s("1")]
      assert get_resp_header(conn, "location") == ["/v1/categories/orders"]

      assert code(create(ctx.token, category("orders", "marketing")), 409) == "resource_conflict"
      assert F.body(F.request(:get, "/v1/categories/orders", ctx.token), 200)["id"] == body["id"]
    end

    test "PC-57, PC-6: security is always locked, marketing is never and its paid channels stay off",
         ctx do
      security = F.body(create(ctx.token, category("alerts", "security")), 201)
      assert security["locked"] == true

      locked = category("news", "marketing", %{"locked" => true})
      assert code(create(ctx.token, locked), 422) == "category_lock_not_allowed"

      loud = category("promo", "marketing", %{"channel_defaults" => %{"email" => "on"}})
      assert code(create(ctx.token, loud), 422) == "category_default_forbidden"

      quiet = category("promo", "marketing", %{"channel_defaults" => %{"push" => "on"}})
      assert F.body(create(ctx.token, quiet), 201)["channel_defaults"] == %{"push" => "on"}
    end

    test "PC-57: settings the class does not allow are field errors", ctx do
      expiring = category("alerts", "security", %{"default_expires_in" => "PT1H"})
      problem = F.body(create(ctx.token, expiring), 422)
      assert problem["code"] == "validation_failed"
      assert [%{"pointer" => "/default_expires_in", "code" => "not_allowed"}] = problem["errors"]

      frequency = %{"limit" => 3, "window" => "PT1H", "fate" => "drop"}
      capped = category("receipts", "transactional", %{"frequency" => frequency})
      problem = F.body(create(ctx.token, capped), 422)
      assert [%{"pointer" => "/frequency", "code" => "not_allowed"}] = problem["errors"]

      digest = category("receipts", "transactional", %{"digest_allowed" => true})
      problem = F.body(create(ctx.token, digest), 422)
      assert [%{"pointer" => "/digest_allowed", "code" => "not_allowed"}] = problem["errors"]

      long = category("receipts", "transactional", %{"default_expires_in" => "P31D"})
      problem = F.body(create(ctx.token, long), 422)

      assert [%{"pointer" => "/default_expires_in", "code" => "unsupported_value"}] =
               problem["errors"]

      ok =
        category("digests", "operational", %{
          "frequency" => %{"limit" => 5, "window" => "P1D", "fate" => "defer"},
          "default_expires_in" => "PT12H",
          "digest_allowed" => true
        })

      body = F.body(create(ctx.token, ok), 201)
      assert body["frequency"] == %{"limit" => 5, "window" => "P1D", "fate" => "defer"}
      assert body["default_expires_in"] == "PT12H"
      assert body["digest_allowed"] == true
    end

    test "WF-30: a density threshold is a validated, audited category setting", ctx do
      density = %{"limit" => 5, "window" => "PT10M", "per" => "device"}
      social = category("friends", "social", %{"density" => density})
      body = F.body(create(ctx.token, social), 201)
      assert body["density"] == density

      plain = F.body(create(ctx.token, category("orders", "transactional")), 201)
      assert plain["density"] == nil

      refused = category("receipts", "transactional", %{"density" => density})
      problem = F.body(create(ctx.token, refused), 422)
      assert [%{"pointer" => "/density", "code" => "not_allowed"}] = problem["errors"]

      long = category("news", "marketing", %{"density" => %{density | "window" => "P2D"}})
      problem = F.body(create(ctx.token, long), 422)

      assert [%{"pointer" => "/density/window", "code" => "unsupported_value"}] =
               problem["errors"]

      undigested = category("ops", "operational", %{"density" => density})
      assert code(create(ctx.token, undigested), 422) == "validation_failed"

      changed = %{"density" => %{"limit" => 3, "window" => "PT5M"}}
      patched = F.body(patch(ctx.token, "friends", changed, [{"if-match", ~s("1")}]), 200)
      assert patched["density"] == %{"limit" => 3, "window" => "PT5M", "per" => "recipient"}

      clear = %{"density" => nil}
      cleared = F.body(patch(ctx.token, "friends", clear, [{"if-match", ~s("2")}]), 200)
      assert cleared["density"] == nil
      assert length(audit(ctx.scope, "category.updated")) == 2
    end

    test "PC-57, API-10: a repeated create replays the stored answer and creates nothing", ctx do
      key = F.key()
      first = create(ctx.token, category("orders", "transactional"), [key])
      body = F.body(first, 201)
      again = create(ctx.token, category("orders", "transactional"), [key])

      assert again.status == 201
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
      assert Jason.decode!(again.resp_body) == body
      assert length(audit(ctx.scope, "category.created")) == 1
    end

    test "PC-57, PC-11: a merge patch needs If-Match, keeps the class and audits a lock change",
         ctx do
      F.body(create(ctx.token, category("orders", "transactional")), 201)

      assert code(patch(ctx.token, "orders", %{"name" => "Orders"}, []), 428) ==
               "precondition_required"

      stale = patch(ctx.token, "orders", %{"name" => "Orders"}, [{"if-match", ~s("7")}])
      assert code(stale, 412) == "precondition_failed"

      [etag] = etag(ctx.token, "orders")
      body = %{"locked" => true, "channel_defaults" => %{"sms" => "on"}}
      updated = F.body(patch(ctx.token, "orders", body, [{"if-match", etag}]), 200)
      assert updated["locked"] == true
      assert updated["channel_defaults"] == %{"sms" => "on"}
      assert updated["message_class"] == "transactional"
      assert updated["version"] == 2

      [etag] = etag(ctx.token, "orders")
      cleared = %{"channel_defaults" => %{"sms" => nil}, "name" => "Order news"}
      updated = F.body(patch(ctx.token, "orders", cleared, [{"if-match", etag}]), 200)
      assert updated["channel_defaults"] == %{}
      assert updated["name"] == "Order news"
      assert updated["locked"] == true

      assert [%{"target_type" => "category"}] = audit(ctx.scope, "category.lock_changed")
      assert [%{"target_type" => "category"}] = audit(ctx.scope, "category.updated")

      unknown = patch(ctx.token, "nowhere", %{"name" => "x"}, [{"if-match", ~s("1")}])
      assert code(unknown, 404) == "category_not_found"
    end

    test "PC-57: archiving keeps the row, is idempotent and an archived category is not changed",
         ctx do
      F.body(create(ctx.token, category("orders", "transactional")), 201)
      archived = F.body(F.request(:post, "/v1/categories/orders/archive", ctx.token), 200)

      assert archived["state"] == "archived"
      assert is_binary(archived["archived_at"])
      again = F.body(F.request(:post, "/v1/categories/orders/archive", ctx.token), 200)
      assert again["version"] == archived["version"]

      [etag] = etag(ctx.token, "orders")

      assert code(patch(ctx.token, "orders", %{"name" => "x"}, [{"if-match", etag}]), 409) ==
               "category_archived"

      listed = F.body(F.request(:get, "/v1/categories", ctx.token), 200)
      assert Enum.map(listed["data"], & &1["key"]) == ["orders"]
      assert [%{"target_type" => "category"}] = audit(ctx.scope, "category.archived")

      assert code(F.request(:post, "/v1/categories/nowhere/archive", ctx.token), 404) ==
               "category_not_found"
    end

    test "API-56: categories are listed newest first in pages", ctx do
      for key <- ~w(alpha beta gamma),
          do: F.body(create(ctx.token, category(key, "operational")), 201)

      first = F.body(F.request(:get, "/v1/categories?limit=2", ctx.token), 200)
      assert Enum.map(first["data"], & &1["key"]) == ["gamma", "beta"]
      assert first["has_more"] == true

      path = "/v1/categories?limit=2&starting_after=" <> first["next_cursor"]
      second = F.body(F.request(:get, path, ctx.token), 200)
      assert Enum.map(second["data"], & &1["key"]) == ["alpha"]
      assert second["has_more"] == false
    end

    test "API-79: reading needs read or config and writing needs config", ctx do
      reader = F.token(ctx.scope, ["read"])
      F.body(create(ctx.token, category("orders", "transactional")), 201)

      assert F.body(F.request(:get, "/v1/categories/orders", reader), 200)["key"] == "orders"

      assert code(create(reader, category("other", "transactional")), 403) ==
               "auth_insufficient_scope"

      publisher = F.token(ctx.scope, ["publish"])

      assert code(F.request(:get, "/v1/categories", publisher), 403) == "auth_insufficient_scope"
    end

    test "PC-57: another tenant's category is 404", ctx do
      F.body(create(ctx.token, category("orders", "transactional")), 201)
      other = F.token(TenantFixture.tenant!().live)

      assert code(F.request(:get, "/v1/categories/orders", other), 404) == "category_not_found"
      assert code(F.request(:get, "/v1/categories/Not-A-Key", other), 404) == "category_not_found"
    end
  end

  describe "PC-57 PC-7 sub-tenant settings" do
    test "PC-7: a sub-tenant overrides only its four fields; first write is 201, then 200", ctx do
      F.body(create(ctx.token, category("news", "marketing")), 201)
      subtenant = Relay.ExternalId.encode("stn", TenantFixture.subtenant!(ctx.scope))
      path = "/v1/categories/news/subtenants/" <> subtenant

      empty = F.body(F.request(:get, path, ctx.token), 200)

      assert %{"enabled" => nil, "channel_defaults" => nil, "version" => 0, "created_at" => nil} =
               empty

      body = %{
        "enabled" => false,
        "frequency" => %{"limit" => 2, "window" => "P7D", "fate" => "drop"}
      }

      created = F.body(F.request(:put, path, ctx.token, body), 201)
      assert created["enabled"] == false
      assert created["frequency"] == %{"limit" => 2, "window" => "P7D", "fate" => "drop"}
      assert created["channel_defaults"] == nil
      assert created["version"] == 1

      replaced = F.body(F.request(:put, path, ctx.token, %{"enabled" => true}), 200)
      assert replaced["enabled"] == true
      assert replaced["frequency"] == nil
      assert replaced["version"] == 2

      loud = %{"channel_defaults" => %{"sms" => "on"}}
      assert code(F.request(:put, path, ctx.token, loud), 422) == "category_default_forbidden"

      assert [_, _] = audit(ctx.scope, "category_subtenant_setting.changed")
    end

    test "PC-7: an unknown sub-tenant or category is 404 and an archived category is 409", ctx do
      F.body(create(ctx.token, category("news", "marketing")), 201)
      other = Relay.ExternalId.encode("stn", Relay.Id.generate())
      unknown = "/v1/categories/news/subtenants/" <> other
      assert code(F.request(:get, unknown, ctx.token), 404) == "subtenant_not_found"

      malformed = "/v1/categories/news/subtenants/stn_bad"
      assert code(F.request(:put, malformed, ctx.token, %{}), 404) == "subtenant_not_found"

      subtenant = Relay.ExternalId.encode("stn", TenantFixture.subtenant!(ctx.scope))
      missing = "/v1/categories/none/subtenants/" <> subtenant
      assert code(F.request(:get, missing, ctx.token), 404) == "category_not_found"

      F.body(F.request(:post, "/v1/categories/news/archive", ctx.token), 200)
      path = "/v1/categories/news/subtenants/" <> subtenant
      archived = F.request(:put, path, ctx.token, %{"enabled" => false})
      assert code(archived, 409) == "category_archived"
    end
  end
end
