defmodule RelayWeb.Api.EscalationPoliciesTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @path "/v1/escalation_policies"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    %{scope: scope, token: F.token(scope, ["agents"]), manager: F.token(scope)}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp subscriber!(ctx) do
    external_id = "user-" <> TenantFixture.random()
    body = %{"external_id" => external_id, "email" => "ayse@example.com"}
    F.body(F.request(:post, "/v1/subscribers", ctx.manager, body), 201)
    external_id
  end

  defp agent!(ctx) do
    id = TenantFixture.recipient!(ctx.scope, %{}, kind: :agent)
    Relay.ExternalId.encode("agt", id)
  end

  defp write(ctx, key, tiers, headers \\ []) do
    body = %{"description" => "on call", "tiers" => tiers}
    F.request(:put, @path <> "/" <> key, ctx.token, body, headers)
  end

  defp read(ctx, path), do: F.request(:get, @path <> path, ctx.token)

  defp archive(ctx, key, headers \\ []),
    do: F.request(:post, @path <> "/" <> key <> "/archive", ctx.token, nil, headers)

  defp match(version), do: [{"if-match", ~s("#{version}")}]

  defp pointers(problem), do: Enum.map(problem["errors"], &{&1["pointer"], &1["code"]})

  defp question(ctx, responders, plan) do
    key = "ck-" <> TenantFixture.random()
    expires = ctx.scope |> Relay.Clock.business_now() |> DateTime.add(3_600, :second)

    body = %{
      "kind" => "question",
      "waiter" => %{"kind" => "agent", "id" => agent!(ctx)},
      "match" => %{"type" => "refund.decided", "correlation_key" => key},
      "expires_at" => DateTime.to_iso8601(expires),
      "response_schema" => %{"type" => "object"},
      "responders" => responders,
      "subject_digest" => "sha256:" <> String.duplicate("ab", 32),
      "content" => %{"action" => "refund"},
      "actions" => [%{"id" => "accept", "label" => "Accept"}]
    }

    F.request(:post, "/v1/waitpoints", ctx.manager, Map.merge(body, plan))
  end

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

    for row <- rows, do: row["target_type"]
  end

  describe "AG-17 escalation policies" do
    test "AG-17: the first write creates version 1 and a later one opens a new version", ctx do
      person = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      agent = %{"kind" => "agent", "id" => agent!(ctx)}

      tiers = [
        %{"after" => "PT2H", "add_responders" => [person], "channels" => ["sms"]},
        %{"after" => "PT8H", "add_responders" => [agent], "repeat" => 1}
      ]

      stored = [
        %{
          "after" => "PT2H",
          "add_responders" => [person],
          "channels" => ["sms"],
          "repeat" => 0,
          "skip_if_empty" => true
        },
        %{
          "after" => "PT8H",
          "add_responders" => [agent],
          "channels" => [],
          "repeat" => 1,
          "skip_if_empty" => true
        }
      ]

      conn = write(ctx, "on-call", tiers)
      body = F.body(conn, 201)

      assert "esp_" <> _ = body["id"]

      assert %{
               "object" => "escalation_policy",
               "key" => "on-call",
               "version" => 1,
               "state" => "active",
               "description" => "on call",
               "tiers" => ^stored
             } = body

      assert get_resp_header(conn, "etag") == [~s("1")]
      assert get_resp_header(conn, "location") == [@path <> "/on-call"]
      assert audit(ctx.scope, "escalation_policy.created") == ["escalation_policy"]

      assert code(write(ctx, "on-call", tiers), 428) == "precondition_required"
      assert code(write(ctx, "on-call", tiers, match(7)), 412) == "precondition_failed"
      assert code(write(ctx, "other", tiers, match(1)), 412) == "precondition_failed"

      shorter = [hd(tiers)]
      next = write(ctx, "on-call", shorter, match(1))
      assert %{"version" => 2, "tiers" => [_one]} = F.body(next, 200)
      assert get_resp_header(next, "etag") == [~s("2")]
      assert audit(ctx.scope, "escalation_policy.updated") == ["escalation_policy"]

      shown = read(ctx, "/on-call")
      assert %{"id" => id, "version" => 2, "tiers" => [first]} = F.body(shown, 200)
      assert id == body["id"]
      assert first == hd(stored)
      assert get_resp_header(shown, "etag") == [~s("2")]

      versions = F.body(read(ctx, "/on-call/versions"), 200)
      assert Enum.map(versions["data"], & &1["version"]) == [2, 1]
      assert [latest, earliest] = versions["data"]
      assert %{"tiers" => [^first], "version" => 2} = latest
      assert %{"tiers" => ^stored, "key" => "on-call"} = earliest
      assert Enum.all?(versions["data"], &(&1["object"] == "escalation_policy_version"))
    end

    test "AG-17: list pages the policies, filters by state and an unknown key is 404", ctx do
      tiers = [%{"after" => "PT1M"}]
      F.body(write(ctx, "alpha", tiers), 201)
      F.body(write(ctx, "beta", tiers), 201)

      listed = F.body(read(ctx, ""), 200)
      assert Enum.sort(Enum.map(listed["data"], & &1["key"])) == ["alpha", "beta"]
      assert listed["has_more"] == false

      page = F.body(read(ctx, "?limit=1"), 200)
      assert [%{"key" => newest}] = page["data"]
      assert page["has_more"] == true
      rest = F.body(read(ctx, "?limit=1&starting_after=" <> page["next_cursor"]), 200)
      assert [%{"key" => oldest}] = rest["data"]
      assert Enum.sort([newest, oldest]) == ["alpha", "beta"]

      assert F.body(read(ctx, "?state=archived"), 200)["data"] == []
      F.body(archive(ctx, "alpha"), 200)
      assert [%{"key" => "alpha"}] = F.body(read(ctx, "?state=archived"), 200)["data"]
      assert [%{"key" => "beta"}] = F.body(read(ctx, "?state=active"), 200)["data"]

      problem = F.body(read(ctx, "?state=gone"), 422)
      assert pointers(problem) == [{"/state", "unsupported_value"}]

      assert code(read(ctx, "/missing"), 404) == "escalation_policy_not_found"
      assert code(read(ctx, "/Not_A_Key"), 404) == "escalation_policy_not_found"
      assert code(read(ctx, "/missing/versions"), 404) == "escalation_policy_not_found"
      refused = F.body(write(ctx, "Not_A_Key", tiers), 422)
      assert pointers(refused) == [{"/policy_key", "invalid_format"}]
    end

    test "AG-17: archiving keeps the row, is idempotent and an archived policy takes no version",
         ctx do
      tiers = [%{"after" => "PT1M"}]
      F.body(write(ctx, "old", tiers), 201)

      assert code(archive(ctx, "old", match(4)), 412) == "precondition_failed"

      archived = archive(ctx, "old", match(1))
      assert %{"state" => "archived", "version" => 1, "key" => "old"} = F.body(archived, 200)
      assert get_resp_header(archived, "etag") == [~s("1")]
      assert %{"state" => "archived"} = F.body(archive(ctx, "old"), 200)
      assert audit(ctx.scope, "escalation_policy.archived") == ["escalation_policy"]

      assert code(write(ctx, "old", tiers, match(1)), 422) == "escalation_policy_archived"
      assert %{"state" => "archived", "version" => 1} = F.body(read(ctx, "/old"), 200)
      assert code(archive(ctx, "missing"), 404) == "escalation_policy_not_found"
    end
  end

  describe "AG-17 AG-63 AG-12 the plan of a waitpoint on the API" do
    test "AG-17, AG-63: a waitpoint takes an inline policy and a surface policy and shows them",
         ctx do
      first = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      second = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      step = %{"surfaces" => [%{"channel" => "sms"}], "escalate_after" => "PT2M"}
      surface = %{"recipients" => [%{"responder" => first, "steps" => [step]}]}
      tiers = [%{"after" => "PT5M", "add_responders" => [second], "repeat" => 1}]
      plan = %{"escalation_policy" => %{"tiers" => tiers}, "surface_policy" => surface}

      created = F.body(question(ctx, [first, second], plan), 201)
      assert created["escalation_policy"] == %{"key" => nil, "version" => 1, "inline" => true}
      assert created["surface_policy"] == surface

      shown = F.body(F.request(:get, "/v1/waitpoints/" <> created["id"], ctx.manager), 200)
      assert shown["escalation_policy"] == created["escalation_policy"]
      assert shown["surface_policy"] == surface

      {:ok, id} = Relay.ExternalId.decode(created["id"], ["wp"])
      {:ok, steps} = Relay.Agents.waitpoint_steps(ctx.scope, id)

      assert Enum.map(steps, &{&1["track"], &1["state"]}) == [
               {"escalation", "armed"},
               {"escalation", "pending"},
               {"surface", "fired"},
               {"surface", "armed"}
             ]

      {:ok, [invitation]} = Relay.Agents.waitpoint_invitations(ctx.scope, id)
      assert invitation["surfaces"] == [%{"channel" => "sms"}]
    end

    test "AG-17: a waitpoint pins the stored policy it names by key", ctx do
      first = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      F.body(write(ctx, "on-call", [%{"after" => "PT1M"}]), 201)

      plan = %{"escalation_policy" => %{"key" => "on-call"}}
      created = F.body(question(ctx, [first], plan), 201)
      pinned = %{"key" => "on-call", "version" => 1, "inline" => false}
      assert created["escalation_policy"] == pinned

      plain = F.body(question(ctx, [first], %{}), 201)
      assert plain["escalation_policy"] == nil
      refute Map.has_key?(plain, "surface_policy")

      missing = question(ctx, [first], %{"escalation_policy" => %{"key" => "nobody"}})
      assert code(missing, 404) == "escalation_policy_not_found"
      F.body(archive(ctx, "on-call"), 200)
      assert code(question(ctx, [first], plan), 422) == "escalation_policy_archived"
    end

    test "AG-12, AG-53: a plan outside the responders or over the limit opens nothing", ctx do
      first = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      outsider = %{"kind" => "subscriber", "id" => subscriber!(ctx)}
      step = %{"surfaces" => [%{"channel" => "sms"}], "escalate_after" => "PT2M"}
      inbox = %{"surfaces" => [%{"channel" => "in_app"}], "escalate_after" => "PT2M"}

      tier = %{"after" => "PT1M", "add_responders" => [outsider]}
      outside = %{"escalation_policy" => %{"tiers" => [tier]}}
      assert code(question(ctx, [first], outside), 422) == "escalation_responder_outside_set"

      long = %{"escalation_policy" => %{"tiers" => List.duplicate(%{"after" => "PT1M"}, 11)}}
      problem = F.body(question(ctx, [first], long), 422)
      assert [%{"code" => "too_long", "limit" => 10, "actual" => 11} = error] = problem["errors"]
      assert error["pointer"] == "/escalation_policy/tiers"

      foreign = %{"recipients" => [%{"responder" => outsider, "steps" => [step]}]}
      problem = F.body(question(ctx, [first], %{"surface_policy" => foreign}), 422)
      assert pointers(problem) == [{"/surface_policy/recipients", "not_allowed"}]

      at_once = %{"recipients" => [%{"responder" => first, "steps" => [inbox]}]}
      problem = F.body(question(ctx, [first], %{"surface_policy" => at_once}), 422)
      pointer = "/surface_policy/recipients/0/steps/0/surfaces/0/channel"
      assert pointers(problem) == [{pointer, "not_allowed"}]

      listed = F.body(F.request(:get, "/v1/waitpoints", ctx.manager), 200)
      assert listed["data"] == []
    end
  end

  describe "AG-53 AG-17 tier checks" do
    test "AG-53: more tiers than the limit are refused with the limit in the error body", ctx do
      limit = Relay.Limits.fetch!(["waitpoint", "max_escalation_tiers"])
      tiers = List.duplicate(%{"after" => "PT1M"}, limit + 1)

      problem = F.body(write(ctx, "long", tiers), 422)
      assert problem["code"] == "validation_failed"

      assert [%{"pointer" => "/tiers", "code" => "too_long"} = error] = problem["errors"]
      assert error["limit"] == limit
      assert error["actual"] == limit + 1
      assert limit == 10
      assert code(read(ctx, "/long"), 404) == "escalation_policy_not_found"
      assert %{"version" => 1} = F.body(write(ctx, "long", Enum.take(tiers, limit)), 201)
    end

    test "AG-17: an unknown responder and a short or unfixed wait are field errors", ctx do
      nobody = %{"kind" => "subscriber", "id" => "nobody"}
      ghost = %{"kind" => "agent", "id" => Relay.ExternalId.encode("agt", Relay.Id.generate())}
      broken = %{"kind" => "agent", "id" => "agt_not-an-id"}

      tiers = [
        %{"after" => "PT30S"},
        %{"after" => "P1M"},
        %{"after" => "P31D"},
        %{"after" => "PT1H", "add_responders" => [nobody, ghost, broken]}
      ]

      problem = F.body(write(ctx, "wrong", tiers), 422)
      assert problem["code"] == "validation_failed"

      assert pointers(problem) == [
               {"/tiers/0/after", "too_short"},
               {"/tiers/1/after", "invalid_format"},
               {"/tiers/2/after", "too_long"},
               {"/tiers/3/add_responders/0", "not_found"},
               {"/tiers/3/add_responders/1", "not_found"},
               {"/tiers/3/add_responders/2", "not_found"}
             ]

      assert code(read(ctx, "/wrong"), 404) == "escalation_policy_not_found"
    end
  end
end
