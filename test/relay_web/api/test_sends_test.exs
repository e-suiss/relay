defmodule RelayWeb.Api.TestSendsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"
  @limit Relay.Limits.fetch!(["test_send", "max_test_recipients"])

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    app = FakeAccess.client!(scope, ["read"])
    F.workflow!(scope, token, "test-send")

    %{tenant: tenant, scope: scope, token: token, app: app}
  end

  defp subscriber!(ctx) do
    external_id = "pairwise-" <> FakeAccess.random()
    body = %{"external_id" => external_id, "email" => "tester@example.com"}
    F.body(F.request(:post, "/v1/subscribers", ctx.token, body), 201)
    external_id
  end

  defp mine!(ctx, external_id) do
    token = FakeAccess.user_token(ctx.tenant.attrs.access_tenant_id, ctx.app, external_id)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type,
      "scope" => "preferences"
    }

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    conn =
      :post
      |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
      |> Api.call(RelayWeb.Router)

    F.body(conn, 200)["access_token"]
  end

  defp add(ctx, external_id, status \\ 201) do
    body = %{"subscriber_id" => external_id}
    F.body(F.request(:post, "/v1/test_recipients", ctx.token, body), status)
  end

  defp confirm(token, id, status) do
    F.body(F.request(:post, "/v1/subscriber/test_recipients/#{id}/confirm", token), status)
  end

  defp verified!(ctx) do
    external_id = subscriber!(ctx)
    entry = add(ctx, external_id)
    confirm(mine!(ctx, external_id), entry["id"], 200)
  end

  defp send_test(ctx, ids, status) do
    body = %{"to" => ids, "data" => %{"order" => "A-1"}}
    F.body(F.request(:post, "/v1/workflows/test-send/test", ctx.token, body), status)
  end

  defp events_is_test(scope, id) do
    {:ok, internal} = Relay.ExternalId.decode(id, ["evt"])
    sql = "SELECT is_test FROM relay.events WHERE id = $1"
    read = fn _status -> Repo.scoped_query!(sql, [internal]).rows end
    {:ok, [[flag]]} = Repo.in_scope(scope, read)
    flag
  end

  describe "API-61 test recipients" do
    test "API-61: an entry is pending until the subscriber confirms it with its own token", ctx do
      external_id = subscriber!(ctx)
      entry = add(ctx, external_id)

      assert %{"state" => "pending", "subscriber_id" => ^external_id, "device_id" => nil} = entry
      assert add(ctx, external_id, 200)["id"] == entry["id"]

      listed = F.body(F.request(:get, "/v1/test_recipients", ctx.token), 200)["data"]
      assert Enum.map(listed, & &1["id"]) == [entry["id"]]

      token = mine!(ctx, external_id)
      mine = F.body(F.request(:get, "/v1/subscriber/test_recipients", token), 200)["data"]
      assert Enum.map(mine, & &1["id"]) == [entry["id"]]

      assert %{"state" => "verified", "verified_at" => at} = confirm(token, entry["id"], 200)
      assert at != nil
      assert confirm(token, entry["id"], 200)["state"] == "verified"
    end

    test "API-61: another subscriber can never confirm an entry", ctx do
      entry = add(ctx, subscriber!(ctx))
      other = mine!(ctx, subscriber!(ctx))

      assert confirm(other, entry["id"], 404)["code"] == "test_recipient_not_found"
    end

    test "API-61: the list holds at most the contract's limit of entries", ctx do
      for _ <- 1..@limit, do: add(ctx, subscriber!(ctx))

      problem = add(ctx, subscriber!(ctx), 422)
      assert problem["code"] == "test_recipient_limit_reached"
      assert problem["limit"] == @limit
    end

    test "API-61: an unknown subscriber is 404", ctx do
      assert add(ctx, "nobody-" <> FakeAccess.random(), 404)["code"] == "subscriber_not_found"
    end

    test "API-61: a removed entry is kept and frees its place", ctx do
      external_id = subscriber!(ctx)
      entry = add(ctx, external_id)
      path = "/v1/test_recipients/#{entry["id"]}/remove"

      assert F.body(F.request(:post, path, ctx.token), 200)["state"] == "removed"
      assert F.body(F.request(:post, path, ctx.token), 200)["state"] == "removed"
      assert F.body(F.request(:get, "/v1/test_recipients", ctx.token), 200)["data"] == []
      assert add(ctx, external_id)["id"] != entry["id"]
    end
  end

  describe "API-61 TP-38 test send" do
    test "API-61: a test send to verified recipients is accepted and marked is_test", ctx do
      entry = verified!(ctx)
      accepted = send_test(ctx, [entry["id"]], 202)

      assert accepted["recipient_count"] == 1
      assert events_is_test(ctx.scope, accepted["id"])

      tests = F.body(F.request(:get, "/v1/notifications?is_test=true", ctx.token), 200)["data"]
      assert [%{"is_test" => true}] = tests
      others = F.body(F.request(:get, "/v1/notifications?is_test=false", ctx.token), 200)
      assert others["data"] == []
    end

    test "API-61: a pending or unknown test recipient is refused", ctx do
      pending = add(ctx, subscriber!(ctx))
      unknown = Relay.ExternalId.encode("trc", Relay.Id.generate())
      problem = send_test(ctx, [pending["id"], unknown], 422)

      assert problem["code"] == "recipient_invalid"
      assert Enum.map(problem["errors"], & &1["pointer"]) == ["/to/0", "/to/1"]
    end

    test "API-61: a test send to an unknown workflow is 404", ctx do
      entry = verified!(ctx)
      body = %{"to" => [entry["id"]]}
      conn = F.request(:post, "/v1/workflows/no-such-flow/test", ctx.token, body)

      assert F.body(conn, 404)["code"] == "workflow_not_found"
    end

    test "API-61: test sends have their own daily quota", ctx do
      consume = fn count, limit ->
        {:ok, result} =
          Repo.in_scope(ctx.scope, fn _status -> Relay.Ingest.test_send_consume(count, limit) end)

        result
      end

      assert consume.(2, 3) == {:consumed, 2}
      assert consume.(2, 3) == {:exhausted, 2}
      assert consume.(1, 3) == {:consumed, 3}
    end
  end
end
