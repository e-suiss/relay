defmodule RelayWeb.Api.CampaignsTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Campaigns
  alias Relay.Api.Campaigns.Engine
  alias Relay.Api.Campaigns.Preparer
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @workflow "campaign-news"

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, @workflow)
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp subscriber!(token) do
    id = "cmp-" <> TenantFixture.random()
    body = %{"external_id" => id, "email" => "c@example.com"}
    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    id
  end

  defp deadline(seconds \\ 86_400),
    do: DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), seconds, :second))

  defp body(overrides) do
    Map.merge(
      %{
        "name" => "November news",
        "workflow" => @workflow,
        "data" => %{"order" => "N-1"},
        "expected_count" => 2,
        "deadline" => deadline()
      },
      overrides
    )
  end

  defp create(token, overrides), do: F.request(:post, "/v1/campaigns", token, body(overrides))

  defp created!(token, overrides), do: F.body(create(token, overrides), 201)

  defp post(token, campaign, action, body \\ nil),
    do: F.request(:post, "/v1/campaigns/#{campaign}/#{action}", token, body)

  defp get(token, campaign), do: F.body(F.request(:get, "/v1/campaigns/" <> campaign, token), 200)

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp id(external), do: elem(Relay.ExternalId.decode(external, ["cmp"]), 1)

  defp prepared!(ctx, recipients, overrides \\ %{}) do
    campaign = created!(ctx.token, Map.put(overrides, "recipients", recipients))["id"]
    assert F.body(post(ctx.token, campaign, "prepare"), 202)["state"] == "preparing"
    assert Preparer.run(ctx.scope, id(campaign)) == :ok
    campaign
  end

  defp approved!(ctx, campaign) do
    samples = F.body(F.request(:get, "/v1/campaigns/#{campaign}/samples", ctx.token), 200)
    digest = %{"samples_digest" => samples["samples_digest"]}
    F.body(post(ctx.token, campaign, "approve_samples", digest), 200)
    samples
  end

  defp jobs(worker, key, value) do
    Repo.query!(
      "SELECT args FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>$2 = $3 ORDER BY id",
      [worker, key, value]
    ).rows
    |> List.flatten()
  end

  defp perform(module, args),
    do: module.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})

  defp outbox(scope, campaign) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT event_type FROM relay.outbox_events WHERE stream_key = $1 ORDER BY created_at, id",
          ["campaign:" <> Relay.Id.to_string(id(campaign))]
        ).rows
      end)

    List.flatten(rows)
  end

  describe "API-35 WF-34 WF-54 campaign requests" do
    test "API-35, WF-34, WF-62: the deadline is required and at most P31D ahead", ctx do
      assert code(create(ctx.token, %{"deadline" => deadline(32 * 86_400)}), 422) ==
               "validation_failed"

      assert code(create(ctx.token, %{"deadline" => deadline(-60)}), 422) == "validation_failed"

      conn = F.request(:post, "/v1/campaigns", ctx.token, Map.delete(body(%{}), "deadline"))
      assert code(conn, 422) == "validation_failed"
    end

    test "WF-54, API-35: an audience is a list or a topic, never an attribute query", ctx do
      conn = create(ctx.token, %{"recipients" => ["a"], "topic" => "news"})
      assert code(conn, 422) == "validation_failed"

      conn = create(ctx.token, %{"segment" => %{"country" => "TR"}})
      assert code(conn, 422) == "unknown_field"
    end

    test "API-35: a topic audience fails preparation until topic expansion exists", ctx do
      campaign = created!(ctx.token, %{"topic" => "release-notes"})
      assert campaign["audience"]["kind"] == "topic"
      assert code(post(ctx.token, campaign["id"], "prepare"), 422) == "campaign_topic_unavailable"
    end

    test "API-35, TN-15: another tenant's campaign is 404", ctx do
      campaign = created!(ctx.token, %{})["id"]
      other = F.token(TenantFixture.tenant!().live)
      conn = F.request(:get, "/v1/campaigns/" <> campaign, other)
      assert code(conn, 404) == "campaign_not_found"
    end
  end

  describe "WF-44 X-14 preparation" do
    test "WF-44, WF-52: the audience is built in parts, deduplicated and frozen at preparation",
         ctx do
      a = subscriber!(ctx.token)
      b = subscriber!(ctx.token)
      campaign = created!(ctx.token, %{"recipients" => [a, "nobody-" <> a]})

      assert campaign["state"] == "draft"

      assert campaign["audience"] == %{
               "kind" => "list",
               "topic" => nil,
               "count" => 1,
               "not_found" => 1,
               "expected_count" => 2
             }

      part = %{"recipients" => [a, b]}
      added = F.body(post(ctx.token, campaign["id"], "recipients", part), 200)
      assert %{"added" => 1, "duplicates" => 1, "not_found" => 0, "audience_count" => 2} = added

      assert F.body(post(ctx.token, campaign["id"], "prepare"), 202)["state"] == "preparing"

      conn = post(ctx.token, campaign["id"], "recipients", %{"recipients" => [a]})
      assert code(conn, 409) == "resource_conflict"
    end

    test "X-14, WF-44: preparation previews the audience in a dry run and estimates its cost",
         ctx do
      campaign = prepared!(ctx, [subscriber!(ctx.token), subscriber!(ctx.token)])
      view = get(ctx.token, campaign)

      assert view["state"] == "prepared"
      assert view["workflow"] == %{"key" => @workflow, "version" => 1}
      assert view["mode"] == "normal"
      assert %{"state" => "ready", "evaluated" => 2} = view["preview"]
      assert view["preview"]["reachable"] + length(view["preview"]["drops"]) >= 1
      assert %{"channels" => _channels} = view["preview"]["estimate"]
      assert view["approvals"]["audience"]["required"] == false
      assert outbox(ctx.scope, campaign) == ["campaign.prepared"]
    end
  end

  describe "WF-62 campaign safety" do
    test "WF-62, OP-47: the trigger needs the approval of the deterministic sample renders",
         ctx do
      campaign = prepared!(ctx, [subscriber!(ctx.token), subscriber!(ctx.token)])

      assert code(post(ctx.token, campaign, "trigger"), 409) == "campaign_approval_required"

      samples = F.body(F.request(:get, "/v1/campaigns/#{campaign}/samples", ctx.token), 200)
      again = F.body(F.request(:get, "/v1/campaigns/#{campaign}/samples", ctx.token), 200)
      assert length(samples["samples"]) == 2
      assert samples["samples_digest"] == again["samples_digest"]
      assert Enum.all?(samples["samples"], &(&1["steps"] != []))

      wrong = %{"samples_digest" => String.duplicate("a", 64)}

      assert code(post(ctx.token, campaign, "approve_samples", wrong), 409) ==
               "campaign_samples_changed"

      approved!(ctx, campaign)
      assert F.body(post(ctx.token, campaign, "trigger"), 202)["state"] == "running"
    end

    test "WF-62, OP-37: an audience above 1.5 times expected_count needs a tenant administrator",
         ctx do
      recipients = [subscriber!(ctx.token), subscriber!(ctx.token)]
      campaign = prepared!(ctx, recipients, %{"expected_count" => 1})
      assert get(ctx.token, campaign)["approvals"]["audience"]["required"] == true

      approved!(ctx, campaign)
      assert code(post(ctx.token, campaign, "trigger"), 409) == "campaign_approval_required"

      admin = TenantFixture.actor()
      reason = %{"reason" => "a larger list was intended"}

      assert {:ok, {200, %{"approvals" => %{"audience" => %{"approved_at" => _}}}}} =
               Campaigns.operator(:approve_audience, ctx.scope, id(campaign), reason, admin)

      assert F.body(post(ctx.token, campaign, "trigger"), 202)["state"] == "running"
    end
  end

  describe "WF-44 T-23 sending" do
    test "WF-44, T-23: the trigger only sends, through the fan-out, each member once", ctx do
      campaign = prepared!(ctx, [subscriber!(ctx.token), subscriber!(ctx.token)])
      approved!(ctx, campaign)
      F.body(post(ctx.token, campaign, "trigger"), 202)
      cid = id(campaign)

      assert Engine.tick(ctx.scope, cid) == :continue
      view = get(ctx.token, campaign)
      assert [%{"stage" => 1, "percent" => 100, "member_count" => 2}] = view["progress"]["stages"]

      [stage] = stages(ctx.scope, cid)
      [slice] = jobs("Relay.Platform.FanoutSlice", "fanout_id", Relay.Id.to_string(stage))
      assert perform(Relay.Platform.FanoutSlice, slice) == :ok

      [send] = jobs("Relay.Api.Campaigns.SendJob", "campaign_id", Relay.Id.to_string(cid))
      refute Map.has_key?(send, "recipients")
      assert perform(Relay.Api.Campaigns.SendJob, send) == :ok
      assert perform(Relay.Api.Campaigns.SendJob, send) == :ok

      progress = get(ctx.token, campaign)["progress"]
      assert progress["accepted"] == 2
      assert notifications(ctx.scope) == 2

      assert Engine.tick(ctx.scope, cid) == :stop
      assert get(ctx.token, campaign)["state"] == "completed"
      assert "campaign.completed" in outbox(ctx.scope, campaign)
    end

    test "WF-44, T-23 (4): a campaign can be cancelled at any time and sends nothing after",
         ctx do
      campaign = prepared!(ctx, [subscriber!(ctx.token)])
      approved!(ctx, campaign)
      F.body(post(ctx.token, campaign, "trigger"), 202)
      cid = id(campaign)
      assert Engine.tick(ctx.scope, cid) == :continue

      cancelled = F.body(post(ctx.token, campaign, "cancel", %{"reason" => "wrong list"}), 200)
      assert cancelled["state"] == "cancelled"
      assert cancelled["progress"]["cancelled"] == 1

      [stage] = stages(ctx.scope, cid)
      [slice] = jobs("Relay.Platform.FanoutSlice", "fanout_id", Relay.Id.to_string(stage))
      _ = perform(Relay.Platform.FanoutSlice, slice)
      assert jobs("Relay.Api.Campaigns.SendJob", "campaign_id", Relay.Id.to_string(cid)) == []
      assert Engine.tick(ctx.scope, cid) == :stop
      assert notifications(ctx.scope) == 0

      conn = post(ctx.token, campaign, "cancel", %{"reason" => "again"})
      assert code(conn, 409) == "resource_conflict"
    end

    test "TN-40, OP-47: a campaign kill switch pauses a running campaign", ctx do
      campaign = prepared!(ctx, [subscriber!(ctx.token)])
      approved!(ctx, campaign)
      F.body(post(ctx.token, campaign, "trigger"), 202)

      F.body(
        F.request(:post, "/v1/kill_switches", ctx.token, %{
          "scope_kind" => "campaign",
          "scope_ref" => campaign,
          "reason" => "wrong segment",
          "ttl" => "PT1H"
        }),
        201
      )

      assert Engine.tick(ctx.scope, id(campaign)) == :continue
      view = get(ctx.token, campaign)
      assert view["state"] == "paused"
      assert "killswitch." <> _state = view["pause_rule_id"]
      assert "campaign.paused" in outbox(ctx.scope, campaign)
    end
  end

  describe "WF-34 deadline" do
    test "WF-34: at the deadline the members left are counted expired and announced", ctx do
      scope = ctx.tenant.test
      token = F.token(scope)
      F.workflow!(scope, token, @workflow)
      ctx = %{ctx | scope: scope, token: token}

      campaign = prepared!(ctx, [subscriber!(token), subscriber!(token)])
      approved!(ctx, campaign)
      F.body(post(token, campaign, "trigger"), 202)

      F.body(F.request(:post, "/v1/virtual_clock/advance", token, %{"by" => "P2D"}), 200)

      assert Engine.tick(scope, id(campaign)) == :stop
      view = get(token, campaign)
      assert view["state"] == "partial"
      assert view["progress"]["expired"] == 2
      assert view["close_rule_id"] == "campaign.deadline_expired"
      expected = ["campaign.prepared", "campaign.expired", "campaign.partial"]
      assert outbox(scope, campaign) == expected
    end
  end

  defp stages(scope, campaign_id) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT fanout_id FROM relay.campaign_stages WHERE campaign_id = $1 ORDER BY stage_no",
          [campaign_id]
        ).rows
      end)

    List.flatten(rows)
  end

  defp notifications(scope) do
    {:ok, [[n]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!("SELECT count(*) FROM relay.notifications", []).rows
      end)

    n
  end
end
