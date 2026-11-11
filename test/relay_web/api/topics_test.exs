defmodule RelayWeb.Api.TopicsTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{scope: tenant.live, token: token}
  end

  defp subscriber!(ctx) do
    external_id = "user-" <> TenantFixture.random()
    body = %{"external_id" => external_id, "email" => "ayse@example.com"}
    F.body(F.request(:post, "/v1/subscribers", ctx.token, body), 201)
    external_id
  end

  defp topic!(ctx, key, parent \\ nil) do
    body = if parent, do: %{"key" => key, "parent" => parent}, else: %{"key" => key}
    F.body(F.request(:post, "/v1/topics", ctx.token, body), 201)
  end

  defp subscribe(ctx, key, ids, status \\ 200) do
    body = %{"subscribers" => ids}
    F.body(F.request(:post, "/v1/topics/#{key}/subscriptions", ctx.token, body), status)
  end

  defp unsubscribe(ctx, key, ids, status \\ 200) do
    body = %{"subscribers" => ids}
    F.body(F.request(:post, "/v1/topics/#{key}/subscriptions/remove", ctx.token, body), status)
  end

  defp send_to(ctx, to, status \\ 202) do
    body = %{"workflow" => "order-shipped", "to" => to, "data" => %{"order" => "A-1"}}
    F.body(F.request(:post, "/v1/events", ctx.token, body), status)
  end

  defp get(ctx, path), do: F.body(F.request(:get, path, ctx.token), 200)

  defp archive(ctx, key),
    do: F.body(F.request(:post, "/v1/topics/#{key}/archive", ctx.token), 200)

  defp external_ids(accepted),
    do: accepted["notifications"] |> Enum.map(& &1["external_id"]) |> Enum.sort()

  defp audience(scope, event_id) do
    {:ok, id} = Relay.ExternalId.decode(event_id, ["evt"])

    sql = """
    SELECT a.member_count, a.rule_id, count(m.recipient_id) FILTER (WHERE m.also_direct)
    FROM relay.audiences a
    LEFT JOIN relay.audience_members m ON m.tenant_id = a.tenant_id
      AND m.environment = a.environment AND m.audience_id = a.id
    WHERE a.source_kind = 'event' AND a.source_id = $1
    GROUP BY a.member_count, a.rule_id
    """

    {:ok, [row]} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, [id]).rows end)
    row
  end

  describe "WF-51 topics" do
    test "WF-51: a topic is created, read, listed and archived without being deleted", ctx do
      created = topic!(ctx, "project:1")

      assert %{"object" => "topic", "key" => "project:1", "parent" => nil, "state" => "active"} =
               created

      assert "top_" <> _ = created["id"]
      assert get(ctx, "/v1/topics/project:1")["id"] == created["id"]

      listed = get(ctx, "/v1/topics")["data"]
      assert Enum.map(listed, & &1["key"]) == ["project:1"]

      archived = archive(ctx, "project:1")
      assert %{"state" => "archived", "archived_at" => at} = archived
      assert at != nil
      assert archive(ctx, "project:1")["version"] == 2
      assert get(ctx, "/v1/topics/project:1")["state"] == "archived"
    end

    test "WF-51: a topic has at most two levels", ctx do
      topic!(ctx, "project:2")
      assert topic!(ctx, "project:2.task:1", "project:2")["parent"] == "project:2"

      body = %{"key" => "project:2.task:1.sub", "parent" => "project:2.task:1"}
      problem = F.body(F.request(:post, "/v1/topics", ctx.token, body), 422)
      assert problem["code"] == "validation_failed"
      assert [%{"pointer" => "/parent", "code" => "not_allowed"}] = problem["errors"]

      body = %{"key" => "orphan", "parent" => "missing"}
      problem = F.body(F.request(:post, "/v1/topics", ctx.token, body), 422)
      assert [%{"pointer" => "/parent", "code" => "not_found"}] = problem["errors"]

      problem = F.body(F.request(:post, "/v1/topics", ctx.token, %{"key" => "project:2"}), 409)
      assert problem["code"] == "resource_conflict"
    end

    test "WF-51: an archived topic takes no child and no subscription", ctx do
      topic!(ctx, "project:3")
      archive(ctx, "project:3")

      body = %{"key" => "project:3.task:1", "parent" => "project:3"}
      problem = F.body(F.request(:post, "/v1/topics", ctx.token, body), 409)
      assert problem["code"] == "topic_archived"
      assert subscribe(ctx, "project:3", [subscriber!(ctx)], 409)["code"] == "topic_archived"
    end

    test "WF-51: an unknown topic is 404", ctx do
      assert F.body(F.request(:get, "/v1/topics/nothing", ctx.token), 404)["code"] ==
               "topic_not_found"

      assert subscribe(ctx, "nothing", [subscriber!(ctx)], 404)["code"] == "topic_not_found"
    end
  end

  describe "WF-51 subscriptions" do
    test "WF-51: subscribers are added in bulk once each and listed from both sides", ctx do
      topic!(ctx, "project:4")
      [a, b] = [subscriber!(ctx), subscriber!(ctx)]

      added = subscribe(ctx, "project:4", [a, b, a])["data"]
      assert Enum.map(added, & &1["subscriber_id"]) == [a, b]
      assert Enum.all?(added, &match?(%{"state" => "active", "id" => "tsb_" <> _}, &1))
      again = subscribe(ctx, "project:4", [b])["data"]
      assert Enum.map(again, & &1["id"]) == [List.last(added)["id"]]

      listed = get(ctx, "/v1/topics/project:4/subscriptions")["data"]
      assert listed |> Enum.map(& &1["subscriber_id"]) |> Enum.sort() == Enum.sort([a, b])

      mine = get(ctx, "/v1/subscribers/#{a}/subscriptions")
      assert [%{"topic" => "project:4", "subscriber_id" => ^a}] = mine["data"]
    end

    test "WF-51: adding an unknown subscriber writes nothing", ctx do
      topic!(ctx, "project:5")
      known = subscriber!(ctx)

      problem = subscribe(ctx, "project:5", [known, "nobody-" <> TenantFixture.random()], 422)
      assert problem["code"] == "recipient_not_found"
      assert [%{"pointer" => "/subscribers/1", "code" => "not_found"}] = problem["errors"]

      assert get(ctx, "/v1/topics/project:5/subscriptions")["data"] == []
    end

    test "WF-51: unsubscribing keeps the subscription as removed", ctx do
      topic!(ctx, "project:6")
      [a, b] = [subscriber!(ctx), subscriber!(ctx)]
      [added] = subscribe(ctx, "project:6", [a])["data"]

      assert [%{"id" => id, "state" => "removed", "removed_at" => at}] =
               unsubscribe(ctx, "project:6", [a, b])["data"]

      assert id == added["id"] and at != nil
      assert [%{"id" => ^id, "state" => "removed"}] = unsubscribe(ctx, "project:6", [a])["data"]
      assert get(ctx, "/v1/topics/project:6/subscriptions")["data"] == []
      assert get(ctx, "/v1/subscribers/#{a}/subscriptions")["data"] == []

      problem = unsubscribe(ctx, "project:6", ["nobody-" <> TenantFixture.random()], 422)
      assert problem["code"] == "recipient_not_found"
    end
  end

  describe "WF-52 WF-53 L-31 topic fan-out" do
    test "WF-52, L-31: a subscriber reached through several paths gets one notification", ctx do
      topic!(ctx, "project:7")
      topic!(ctx, "project:7.task:1", "project:7")
      [a, b, c, d] = for _ <- 1..4, do: subscriber!(ctx)
      subscribe(ctx, "project:7", [a, b])
      subscribe(ctx, "project:7.task:1", [a, c])

      accepted = send_to(ctx, [%{"topic" => "project:7.task:1"}, %{"topic" => "project:7"}, b, d])

      assert external_ids(accepted) == Enum.sort([a, b, c, d])
      assert accepted["recipient_count"] == 4
      notifications = Enum.map(accepted["notifications"], & &1["notification_id"])
      assert length(Enum.uniq(notifications)) == 4
      assert audience(ctx.scope, accepted["id"]) == [3, nil, 1]
    end

    test "WF-51: an event to a parent topic does not reach the subscribers of its children",
         ctx do
      topic!(ctx, "project:8")
      topic!(ctx, "project:8.task:1", "project:8")
      [a, b] = [subscriber!(ctx), subscriber!(ctx)]
      subscribe(ctx, "project:8", [a])
      subscribe(ctx, "project:8.task:1", [b])

      assert external_ids(send_to(ctx, [%{"topic" => "project:8"}])) == [a]
    end

    test "WF-52: the subscriber list is frozen when the event is accepted", ctx do
      topic!(ctx, "project:9")
      [a, b] = [subscriber!(ctx), subscriber!(ctx)]
      subscribe(ctx, "project:9", [a])

      first = send_to(ctx, [%{"topic" => "project:9"}])
      subscribe(ctx, "project:9", [b])
      unsubscribe(ctx, "project:9", [a])

      assert external_ids(first) == [a]
      assert audience(ctx.scope, first["id"]) == [1, nil, 0]
      assert external_ids(send_to(ctx, [%{"topic" => "project:9"}])) == [b]
    end

    test "WF-53: a topic that reaches no subscriber is recorded with its rule, never dropped",
         ctx do
      topic!(ctx, "project:10")
      accepted = send_to(ctx, [%{"topic" => "project:10"}])

      assert accepted["recipient_count"] == 0
      assert accepted["notifications"] == []

      assert [%{"code" => "topic_no_subscribers", "pointer" => "/to/0"}] = accepted["warnings"]
      assert audience(ctx.scope, accepted["id"]) == [0, "audience.no_subscribers", 0]
    end

    test "WF-53: an unknown topic and an archived topic are refused with their pointer", ctx do
      problem = send_to(ctx, [subscriber!(ctx), %{"topic" => "nothing"}], 422)
      assert problem["code"] == "recipient_not_found"
      assert [%{"pointer" => "/to/1", "code" => "not_found"}] = problem["errors"]

      topic!(ctx, "project:11")
      archive(ctx, "project:11")
      problem = send_to(ctx, [%{"topic" => "project:11"}], 422)
      assert problem["code"] == "recipient_invalid"
      assert [%{"pointer" => "/to/0", "code" => "not_allowed"}] = problem["errors"]
    end
  end
end
