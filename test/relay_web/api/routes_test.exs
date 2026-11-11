defmodule RelayWeb.Api.RoutesTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @tree %{"single" => ["in_app", %{"all" => ["push", "email"]}]}

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp create(token, key, tree \\ @tree) do
    body = %{"key" => key, "name" => "Route " <> key, "tree" => tree}
    F.request(:post, "/v1/routes", token, body)
  end

  defp replace(token, key, body, headers),
    do: F.request(:put, "/v1/routes/" <> key, token, body, headers)

  defp archive(token, key), do: F.request(:post, "/v1/routes/" <> key <> "/archive", token)

  defp patch(token, key, body, headers) do
    path = "/v1/categories/" <> key
    auth = Api.auth(token, :patch, path)
    headers = [{"content-type", "application/merge-patch+json"}, F.key() | auth] ++ headers

    :patch
    |> Api.conn(path, Jason.encode!(body), headers)
    |> Api.call(RelayWeb.Router)
  end

  defp category(token, key, extra) do
    body = Map.merge(%{"key" => key, "name" => key, "message_class" => "transactional"}, extra)
    F.request(:post, "/v1/categories", token, body)
  end

  defp etag(token, path), do: get_resp_header(F.request(:get, path, token), "etag")

  defp pointers(problem), do: Enum.map(problem["errors"], &{&1["pointer"], &1["code"]})

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

  describe "WF-13 named routes" do
    test "WF-13: create answers 201 with an ETag and the tree; the key again is 409", ctx do
      conn = create(ctx.token, "critical")
      body = F.body(conn, 201)

      assert "rte_" <> _ = body["id"]

      assert %{
               "object" => "route",
               "key" => "critical",
               "name" => "Route critical",
               "tree" => @tree,
               "state" => "active",
               "version" => 1,
               "archived_at" => nil
             } = body

      assert get_resp_header(conn, "etag") == [~s("1")]
      assert get_resp_header(conn, "location") == ["/v1/routes/critical"]
      assert [%{"target_type" => "route"}] = audit(ctx.scope, "route.created")

      assert code(create(ctx.token, "critical"), 409) == "resource_conflict"
      assert F.body(F.request(:get, "/v1/routes/critical", ctx.token), 200)["id"] == body["id"]
      missing = F.request(:get, "/v1/routes/missing", ctx.token)
      assert code(missing, 404) == "route_policy_not_found"
    end

    test "WF-15, WF-59: a zero delay, a deep tree and too many channels are field errors", ctx do
      zero = %{"single" => ["push", "email"], "trigger" => %{"after_delay" => "PT0S"}}
      problem = F.body(create(ctx.token, "zero", zero), 422)
      assert problem["code"] == "validation_failed"
      assert pointers(problem) == [{"/tree/trigger/after_delay", "unsupported_value"}]

      deep = %{"single" => [%{"single" => [%{"single" => [%{"single" => ["sms"]}]}]}]}
      problem = F.body(create(ctx.token, "deep", deep), 422)
      assert pointers(problem) == [{"/tree/single/0/single/0/single/0/single/0", "too_long"}]

      wide = %{"all" => List.duplicate("email", 11)}
      assert pointers(F.body(create(ctx.token, "wide", wide), 422)) == [{"/tree", "too_long"}]

      assert code(F.request(:get, "/v1/routes/zero", ctx.token), 404) == "route_policy_not_found"
    end

    test "WF-14: a replacement needs If-Match, applies as a whole and is audited", ctx do
      F.body(create(ctx.token, "alerts"), 201)
      body = %{"name" => "Alerts", "tree" => %{"all" => ["push", "sms"]}}

      assert code(replace(ctx.token, "alerts", body, []), 428) == "precondition_required"
      stale = replace(ctx.token, "alerts", body, [{"if-match", ~s("7")}])
      assert code(stale, 412) == "precondition_failed"

      replaced = replace(ctx.token, "alerts", body, [{"if-match", ~s("1")}])
      assert %{"name" => "Alerts", "version" => 2} = F.body(replaced, 200)

      assert get_resp_header(replaced, "etag") == [~s("2")]
      assert [%{"target_type" => "route"}] = audit(ctx.scope, "route.replaced")

      same = replace(ctx.token, "alerts", body, [{"if-match", ~s("2")}])
      assert F.body(same, 200)["version"] == 2

      missing = replace(ctx.token, "missing", body, [{"if-match", ~s("1")}])
      assert code(missing, 404) == "route_policy_not_found"
    end

    test "WF-14: archiving keeps the row, is idempotent and an archived route is not replaced",
         ctx do
      F.body(create(ctx.token, "old"), 201)

      archived = F.body(archive(ctx.token, "old"), 200)
      assert %{"state" => "archived", "version" => 2} = archived
      assert archived["archived_at"] != nil
      assert F.body(archive(ctx.token, "old"), 200)["version"] == 2
      assert [%{"target_type" => "route"}] = audit(ctx.scope, "route.archived")

      body = %{"name" => "Old", "tree" => "email"}
      stale = replace(ctx.token, "old", body, [{"if-match", ~s("2")}])
      assert code(stale, 409) == "route_policy_archived"
      assert code(archive(ctx.token, "missing"), 404) == "route_policy_not_found"
    end

    test "API-56: routes are listed newest first", ctx do
      for key <- ~w(first second third), do: F.body(create(ctx.token, key), 201)

      page = F.body(F.request(:get, "/v1/routes?limit=2", ctx.token), 200)
      assert Enum.map(page["data"], & &1["key"]) == ["third", "second"]
      assert page["has_more"] == true
    end

    test "WF-13: another tenant's route is 404", ctx do
      F.body(create(ctx.token, "private"), 201)
      other = F.token(TenantFixture.tenant!().live)
      assert code(F.request(:get, "/v1/routes/private", other), 404) == "route_policy_not_found"
    end
  end

  describe "WF-14 category default route" do
    test "WF-14: a category names an existing route as default and changes it by patch", ctx do
      problem = F.body(category(ctx.token, "orders", %{"default_route" => "missing"}), 422)
      assert problem["code"] == "validation_failed"
      assert pointers(problem) == [{"/default_route", "not_found"}]

      F.body(create(ctx.token, "critical"), 201)
      body = F.body(category(ctx.token, "orders", %{"default_route" => "critical"}), 201)
      assert body["default_route"] == "critical"

      [etag] = etag(ctx.token, "/v1/categories/orders")
      cleared = patch(ctx.token, "orders", %{"default_route" => nil}, [{"if-match", etag}])
      assert F.body(cleared, 200)["default_route"] == nil

      [etag] = etag(ctx.token, "/v1/categories/orders")
      set = patch(ctx.token, "orders", %{"default_route" => "critical"}, [{"if-match", etag}])
      assert F.body(set, 200)["default_route"] == "critical"
      assert [_, _] = audit(ctx.scope, "category.updated")
    end

    test "WF-14: a route in use as a default is not archived and an archived route is not named",
         ctx do
      F.body(create(ctx.token, "critical"), 201)
      F.body(category(ctx.token, "orders", %{"default_route" => "critical"}), 201)

      assert code(archive(ctx.token, "critical"), 409) == "route_policy_in_use"

      [etag] = etag(ctx.token, "/v1/categories/orders")
      F.body(patch(ctx.token, "orders", %{"default_route" => nil}, [{"if-match", etag}]), 200)
      F.body(archive(ctx.token, "critical"), 200)

      [etag] = etag(ctx.token, "/v1/categories/orders")
      named = patch(ctx.token, "orders", %{"default_route" => "critical"}, [{"if-match", etag}])
      assert pointers(F.body(named, 422)) == [{"/default_route", "not_allowed"}]
    end

    test "WF-14: a step's route wins over its channel and its channel over the category default",
         ctx do
      F.body(create(ctx.token, "critical"), 201)
      F.body(create(ctx.token, "gone", "sms"), 201)
      F.body(archive(ctx.token, "gone"), 200)
      F.body(category(ctx.token, "orders", %{"default_route" => "critical"}), 201)
      F.body(category(ctx.token, "plain", %{}), 201)

      inline = %{"all" => ["push", "sms"]}

      resolve = fn step, category ->
        {:ok, resolved} =
          Relay.Repo.in_scope(ctx.scope, fn _status ->
            Relay.Workflow.resolve_route(step, category)
          end)

        resolved
      end

      assert resolve.(%{"route" => inline, "channel" => "email"}, "orders") ==
               {:ok, inline, :step}

      assert resolve.(%{"route" => "critical"}, "plain") == {:ok, @tree, :step}
      assert resolve.(%{"channel" => "email"}, "orders") == {:ok, "email", :channel}
      assert resolve.(%{}, "orders") == {:ok, @tree, :category}
      assert resolve.(%{}, "plain") == {:skip, "route.not_found"}
      assert resolve.(%{"route" => "gone"}, "orders") == {:skip, "route.not_found"}
      assert resolve.(%{"route" => "missing"}, "orders") == {:skip, "route.not_found"}
    end

    test "WF-14: a route change applies to the next resolution", ctx do
      F.body(create(ctx.token, "critical"), 201)
      F.body(category(ctx.token, "orders", %{"default_route" => "critical"}), 201)

      body = %{"name" => "Critical", "tree" => "sms"}
      F.body(replace(ctx.token, "critical", body, [{"if-match", ~s("1")}]), 200)

      assert {:ok, {:ok, "sms", :category}} =
               Relay.Repo.in_scope(ctx.scope, fn _status ->
                 Relay.Workflow.resolve_route(%{}, "orders")
               end)
    end
  end
end
