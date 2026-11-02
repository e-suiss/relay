defmodule RelayWeb.Api.WorkflowsTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Api.Views
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    :ok = F.category!(token, "orders")
    %{scope: tenant.live, token: token}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp create(token, key, definition),
    do: F.request(:post, "/v1/workflows", token, %{"key" => key, "definition" => definition})

  defp etag(token, key),
    do: get_resp_header(F.request(:get, "/v1/workflows/" <> key, token), "etag")

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

  describe "WF-5 WF-6 INV-48 workflow lifecycle" do
    test "API-69: create answers 201 with an ETag and a draft; the same key again is 409", ctx do
      conn = create(ctx.token, "welcome", F.definition())
      body = F.body(conn, 201)

      assert body["key"] == "welcome"
      assert body["published_version"] == nil
      assert body["draft"]["category"] == "orders"
      assert get_resp_header(conn, "etag") == [~s("1")]
      assert code(create(ctx.token, "welcome", F.definition()), 409) == "resource_conflict"
    end

    test "S-66: replacing a draft needs If-Match and a fresh version", ctx do
      F.body(create(ctx.token, "welcome", F.definition()), 201)
      body = %{"definition" => F.definition(name: "Welcome v2")}

      assert code(F.request(:put, "/v1/workflows/welcome", ctx.token, body), 428) ==
               "precondition_required"

      stale = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", ~s("9")}])
      assert code(stale, 412) == "precondition_failed"

      [etag] = etag(ctx.token, "welcome")
      fresh = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}])
      assert F.body(fresh, 200)["name"] == "Welcome v2"
    end

    test "WF-6: publication is 202 and the gate publishes version 1", ctx do
      F.body(create(ctx.token, "welcome", F.definition()), 201)
      [etag] = etag(ctx.token, "welcome")
      path = "/v1/workflows/welcome/publish"
      conn = F.request(:post, path, ctx.token, %{}, [{"if-match", etag}])

      accepted = F.body(conn, 202)
      assert accepted["publication"]["status"] == "pending"

      F.run_gates!(ctx.scope)
      shown = F.body(F.request(:get, "/v1/workflows/welcome", ctx.token), 200)
      assert shown["published_version"] == 1
      assert shown["last_publication"]["status"] == "published"
      assert shown["draft"] == nil
    end

    test "WF-6: a definition whose event schema does not build is rejected with field errors",
         ctx do
      definition = F.definition(event_schema: %{"type" => 5})
      F.body(create(ctx.token, "broken", definition), 201)
      shown = F.publish!(ctx.scope, ctx.token, "broken")

      assert shown["published_version"] == nil
      assert shown["last_publication"]["status"] == "rejected"
      assert [%{"pointer" => "/definition/event_schema"}] = shown["last_publication"]["errors"]
    end

    test "INV-48: a published version never changes and promote republishes it as a new version",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "welcome", name: "First")
      [etag] = etag(ctx.token, "welcome")

      body = %{"definition" => F.definition(name: "Second")}
      F.body(F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}]), 200)
      F.publish!(ctx.scope, ctx.token, "welcome")

      first = F.body(F.request(:get, "/v1/workflows/welcome/versions/1", ctx.token), 200)
      assert first["definition"]["name"] == "First"

      promoted = F.request(:post, "/v1/workflows/welcome/versions/1/promote", ctx.token)
      F.body(promoted, 202)
      F.run_gates!(ctx.scope)

      third = F.body(F.request(:get, "/v1/workflows/welcome/versions/3", ctx.token), 200)
      assert third["definition"]["name"] == "First"
      assert third["promoted_from"] == 1
      assert third["definition_digest"] == first["definition_digest"]

      versions = F.body(F.request(:get, "/v1/workflows/welcome/versions", ctx.token), 200)
      assert Enum.map(versions["data"], & &1["version"]) == [3, 2, 1]
    end

    test "PC-57, API-79: a definition without a message class takes the class of its category",
         ctx do
      created = F.body(create(ctx.token, "no-class", F.definition(message_class: nil)), 201)
      assert created["draft"]["message_class"] == "transactional"
      assert created["draft"]["category"] == "orders"

      [etag] = etag(ctx.token, "no-class")
      body = %{"definition" => F.definition(name: "Again", message_class: nil)}
      replaced = F.request(:put, "/v1/workflows/no-class", ctx.token, body, [{"if-match", etag}])
      assert F.body(replaced, 200)["draft"]["message_class"] == "transactional"
    end

    test "PC-57, API-79: an unknown category is a field error and another class is a mismatch",
         ctx do
      unknown = F.body(create(ctx.token, "nowhere", F.definition(category: "missing")), 422)
      assert unknown["code"] == "validation_failed"
      assert [%{"pointer" => "/definition/category", "code" => "not_found"}] = unknown["errors"]

      marketing = F.definition(category: "orders", message_class: "marketing")
      assert code(create(ctx.token, "wrong-class", marketing), 422) == "category_class_mismatch"
      assert code(F.request(:get, "/v1/workflows/wrong-class", ctx.token), 404) ==
               "workflow_not_found"

      F.body(create(ctx.token, "welcome", F.definition()), 201)
      [etag] = etag(ctx.token, "welcome")
      body = %{"definition" => F.definition(message_class: "security")}
      replaced = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}])
      assert code(replaced, 422) == "category_class_mismatch"
    end

    test "PC-57: an archived category takes no new workflow and no new draft", ctx do
      F.body(create(ctx.token, "welcome", F.definition()), 201)
      :ok = F.category!(ctx.token, "old_news", "operational")
      F.body(F.request(:post, "/v1/categories/old_news/archive", ctx.token), 200)

      definition = F.definition(category: "old_news", message_class: nil)
      problem = F.body(create(ctx.token, "late", definition), 422)
      assert [%{"pointer" => "/definition/category", "code" => "not_allowed"}] = problem["errors"]

      [etag] = etag(ctx.token, "welcome")
      body = %{"definition" => definition}
      replaced = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}])
      assert code(replaced, 422) == "validation_failed"
    end

    test "WF-6: an unknown version is 404 workflow_version_not_found", ctx do
      F.workflow!(ctx.scope, ctx.token, "welcome")

      assert code(F.request(:get, "/v1/workflows/welcome/versions/7", ctx.token), 404) ==
               "workflow_version_not_found"
    end
  end

  describe "API-82 workflow audit" do
    test "API-82: create, draft, publication request, publication and promote are audited",
         ctx do
      created = F.body(create(ctx.token, "welcome", F.definition()), 201)
      [etag] = etag(ctx.token, "welcome")
      body = %{"definition" => F.definition(name: "Welcome v2")}
      drafted = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}])
      draft_id = F.body(drafted, 200)["draft_version_id"]
      F.publish!(ctx.scope, ctx.token, "welcome")
      F.body(F.request(:post, "/v1/workflows/welcome/versions/1/promote", ctx.token), 202)
      F.run_gates!(ctx.scope)

      assert [%{"target_type" => "workflow", "target_id" => workflow_id} = row] =
               audit(ctx.scope, "workflow.created")

      assert "wfl_" <> _ = created["id"]
      assert Views.id("wfl", Ecto.UUID.dump!(workflow_id)) == created["id"]
      assert row["actor_kind"] == "api_client"
      assert is_binary(row["actor_ref"])

      assert [%{"target_type" => "workflow_version", "target_id" => drafted_id}] =
               audit(ctx.scope, "workflow.drafted")

      assert Views.id("wfv", Ecto.UUID.dump!(drafted_id)) == draft_id

      assert [%{"target_type" => "workflow_version", "target_id" => ^drafted_id}] =
               audit(ctx.scope, "workflow.publication_requested")

      assert [%{"target_type" => "workflow_version"}] = audit(ctx.scope, "workflow.promoted")
      assert length(audit(ctx.scope, "workflow.published")) == 2

      for action <- ~w(workflow.drafted workflow.publication_requested workflow.promoted),
          row <- audit(ctx.scope, action),
          do: assert(row["actor_kind"] == "api_client")
    end

    test "API-82: an unchanged draft writes no audit record", ctx do
      F.body(create(ctx.token, "welcome", F.definition()), 201)
      [etag] = etag(ctx.token, "welcome")
      body = %{"definition" => F.definition()}
      same = F.request(:put, "/v1/workflows/welcome", ctx.token, body, [{"if-match", etag}])
      F.body(same, 200)

      assert audit(ctx.scope, "workflow.drafted") == []
    end
  end

  describe "API-28 type mappings" do
    test "MD-16: a mapping is created, its duplicate refused and it is archived under If-Match",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "welcome")

      mapping = %{
        "type" => "com.example.signup",
        "workflow" => "welcome",
        "to_pointer" => "/user",
        "data_fields" => ["/name"]
      }

      conn = F.request(:post, "/v1/event_type_mappings", ctx.token, mapping)
      created = F.body(conn, 201)
      assert "cem_" <> _ = created["id"]

      assert code(F.request(:post, "/v1/event_type_mappings", ctx.token, mapping), 409) ==
               "resource_conflict"

      [etag] = get_resp_header(conn, "etag")
      path = "/v1/event_type_mappings/#{created["id"]}/archive"
      archived = F.body(F.request(:post, path, ctx.token, nil, [{"if-match", etag}]), 200)
      assert archived["state"] == "archived"
    end

    test "MD-16: a pointer that is not an RFC 6901 pointer is refused", ctx do
      F.workflow!(ctx.scope, ctx.token, "welcome")

      mapping = %{
        "type" => "com.example.signup",
        "workflow" => "welcome",
        "to_pointer" => "user",
        "data_fields" => [""]
      }

      assert code(F.request(:post, "/v1/event_type_mappings", ctx.token, mapping), 422) ==
               "validation_failed"
    end
  end
end
