defmodule Relay.Agents.EscalationTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  @minute 60_000

  @put "SELECT * FROM relay_fn.escalation_policy_put($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)"
  @archive "SELECT * FROM relay_fn.escalation_policy_archive($1, $2, $3, $4, $5, $6)"
  @check "SELECT * FROM relay_fn.waitpoint_plan_check($1, $2, $3, $4, $5, $6)"
  @pin "SELECT * FROM relay_fn.waitpoint_plan_pin($1, $2, $3, $4, $5, $6)"
  @cancel "SELECT relay_fn.waitpoint_cancel($1, $2, $3, $4, $5, $6, $7)"
  @settle "SELECT * FROM relay_fn.waitpoint_invitation_settle($1, $2)"
  @heartbeat "SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)"
  @steps "SELECT level, state, rule_id FROM relay.waitpoint_steps WHERE waitpoint_id = $1 AND track = 'escalation' ORDER BY ordinal"
  @suspended "SELECT level, state, remaining_ms, rule_id FROM relay.waitpoint_steps WHERE waitpoint_id = $1 ORDER BY ordinal"
  @invitations "SELECT recipient_id, source, surfaces, inbox, state, rule_id FROM relay.waitpoint_invitations WHERE waitpoint_id = $1 ORDER BY id"
  @invitation "SELECT id FROM relay.waitpoint_invitations WHERE waitpoint_id = $1 AND recipient_id = $2 ORDER BY id LIMIT 1"
  @invite "INSERT INTO relay.waitpoint_invitations (tenant_id, environment, id, waitpoint_id, recipient_id, source, inbox, state, invited_at, created_at, updated_at) VALUES ($1, 'test', $2, $3, $4, 'creation', true, 'requested', relay_private.business_now(), now(), now())"
  @revive "UPDATE relay.waitpoint_steps SET state = 'armed', due_at = now(), rule_id = NULL, settled_at = NULL WHERE waitpoint_id = $1"
  @rewrite "UPDATE relay.escalation_policy_versions SET description = 'changed' WHERE policy_id = $1"
  @versions "SELECT version, jsonb_array_length(tiers) FROM relay.escalation_policy_versions WHERE policy_id = $1 ORDER BY version"
  @audited "SELECT action FROM relay.audit_log WHERE target_id = $1 ORDER BY created_at, id"
  @audit_count "SELECT count(*) FROM relay.audit_log WHERE target_id = $1"
  @responders "SELECT recipient_id, added_by FROM relay.waitpoint_responders WHERE waitpoint_id = $1 ORDER BY 1"
  @responses "SELECT count(*) FROM relay.waitpoint_responses WHERE waitpoint_id = $1"
  @levels "SELECT payload->'level' FROM relay.outbox_events WHERE event_type = 'waitpoint.escalated' AND stream_key = $1"
  @expired "SELECT payload_ct, payload_tenant_key_id FROM relay.mailbox_records WHERE mailbox_id = $1 AND event_type = 'waitpoint.expired'"

  setup do
    scenario()
  end

  defp scenario do
    s = setup!()
    agent = member!(s, "agent")
    first = member!(s, "subscriber")
    second = member!(s, "subscriber")

    %{s: s, agent: agent, first: first, second: second, value_key: content_key!(s, first)}
  end

  defp text(id), do: Relay.Id.to_string(id)

  defp tier(after_ms, opts \\ []) do
    ids = Keyword.get(opts, :add, [])
    added = Enum.map(ids, &%{"kind" => "subscriber", "id" => text(&1)})

    %{
      "after_ms" => after_ms,
      "add_responders" => added,
      "channels" => Keyword.get(opts, :channels, []),
      "repeat" => Keyword.get(opts, :repeat, 0),
      "skip_if_empty" => Keyword.get(opts, :skip_if_empty, true)
    }
  end

  defp plan(opts),
    do: [opts[:key], opts[:version], opts[:tiers], opts[:surface], Keyword.get(opts, :max, 10)]

  defp check(responders, opts), do: row(@check, [responders | plan(opts)])
  defp pin(id, opts), do: row(@pin, [id | plan(opts)])

  defp put_policy(key, tiers, expected \\ nil, max \\ 10),
    do: row(@put, [id(), id(), key, "on call", tiers, expected, max, digest() | actor()])

  defp archive_policy(key), do: row(@archive, [key, digest() | actor()])

  defp question(ctx, tiers, opts \\ []) do
    {responders, opts} = Keyword.pop(opts, :responders, [ctx.first, ctx.second])
    base = [waiter_ref: ctx.agent, responder_ids: responders, escalation_policy_ref: "inline"]
    ["opened", id, _, nil] = open(ctx.s, Keyword.merge(base, opts))
    ["pinned", _next] = pin(id, tiers: tiers)
    id
  end

  defp timer(id), do: row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [id])
  defp run(id), do: row("SELECT * FROM relay_fn.waitpoint_steps_fire($1)", [id])
  defp steps(id), do: rows(@steps, [id])
  defp invitations(id), do: rows(@invitations, [id])
  defp invitation(id, recipient), do: one(@invitation, [id, recipient])

  defp settle(invitation_id, outcome), do: row(@settle, [invitation_id, outcome])

  defp answer(ctx, id) do
    digest = waitpoint(id, "subject_digest")
    opts = [responder_recipient_id: ctx.first, value_key_id: ctx.value_key]
    respond(id, [{:subject_digest, digest} | opts])
  end

  defp cancel(id), do: one(@cancel, [id, "no longer needed", digest() | actor()])
  defp events(id), do: mailbox_events(waitpoint(id, "waiter_mailbox_id"))

  describe "AG-17 escalation policy" do
    test "AG-17: a policy is named and versioned and every write opens a new version" do
      assert ["created", policy, 1] = put_policy("on-call", [tier(@minute)])
      assert ["precondition_required", ^policy, 1] = put_policy("on-call", [tier(@minute)])
      assert ["version_conflict", ^policy, 1] = put_policy("on-call", [tier(@minute)], 7)
      assert ["version_conflict", nil, nil] = put_policy("other", [tier(@minute)], 1)

      two = [tier(@minute), tier(2 * @minute)]
      assert ["versioned", ^policy, 2] = put_policy("on-call", two, 1)

      assert rows(@versions, [policy]) == [[1, 1], [2, 2]]
      assert one("SELECT version FROM relay.escalation_policies WHERE id = $1", [policy]) == 2

      assert rows(@audited, [text(policy)]) == [
               ["escalation_policy.created"],
               ["escalation_policy.updated"]
             ]
    end

    test "AG-17: a stored version never changes" do
      as_owner(&scenario/0, fn _ctx ->
        ["created", policy, 1] = put_policy("frozen", [tier(@minute)])
        assert error_message(@rewrite, [policy]) =~ ~r/invariant_violation|permission denied/
        assert rows(@versions, [policy]) == [[1, 1]]
      end)
    end

    test "AG-17: an archived policy takes no new version and no new waitpoint", ctx do
      ["created", policy, 1] = put_policy("retired", [tier(@minute)])

      assert ["ok", "retired:1"] = check([ctx.first], key: "retired")
      assert ["archived", 1] = archive_policy("retired")
      assert ["already_archived", 1] = archive_policy("retired")
      assert ["not_found", nil] = archive_policy("missing")

      assert ["archived", ^policy, 1] = put_policy("retired", [tier(@minute)], 1)
      assert ["policy_archived", nil] = check([ctx.first], key: "retired")
      assert ["policy_not_found", nil] = check([ctx.first], key: "missing")
      assert List.last(rows(@audited, [text(policy)])) == ["escalation_policy.archived"]
    end

    test "AG-17: a waitpoint pins the version it referenced and a later version leaves it alone",
         ctx do
      ["created", _policy, 1] = put_policy("pinned", [tier(@minute)])
      assert ["ok", "pinned:1"] = check([ctx.first], key: "pinned")
      assert ["policy_not_found", nil] = check([ctx.first], key: "pinned", version: 2)

      opts = [waiter_ref: ctx.agent, responder_ids: [ctx.first]]
      ["opened", id, _, nil] = open(ctx.s, [{:escalation_policy_ref, "pinned:1"} | opts])

      assert ["pinned", %DateTime{}] = pin(id, key: "pinned")
      assert ["already_pinned", %DateTime{}] = pin(id, key: "pinned")

      ["versioned", _, 2] = put_policy("pinned", [tier(@minute), tier(@minute)], 1)

      assert steps(id) == [[1, "armed", nil]]
      assert waitpoint(id, "escalation_policy_ref") == "pinned:1"
      assert ["ok", "pinned:2"] = check([ctx.first], key: "pinned")
      assert ["ok", "pinned:1"] = check([ctx.first], key: "pinned", version: 1)
    end

    test "AG-53: more tiers than the limit are refused, stored or inline", ctx do
      eleven = List.duplicate(tier(@minute), 11)
      three = List.duplicate(tier(@minute), 3)

      assert ["tier_limit", nil, nil] = put_policy("too-long", eleven)
      assert ["tier_limit", nil] = check([ctx.first], tiers: eleven)
      assert ["tier_limit", nil] = check([ctx.first], tiers: three, max: 2)
      assert ["ok", "inline"] = check([ctx.first], tiers: List.duplicate(tier(@minute), 10))

      ["created", _policy, 1] = put_policy("ten", List.duplicate(tier(@minute), 10))
      assert ["tier_limit", nil] = check([ctx.first], key: "ten", max: 9)
    end

    test "AG-17: a tier names only responders that exist and waits at least a minute" do
      ghost = [tier(@minute, add: [id()])]
      assert ["responder_not_found", nil, nil] = put_policy("ghost", ghost)

      fast = [id(), id(), "fast", nil, [tier(1_000)], nil, 10, digest() | actor()]
      assert error_message(@put, fast) =~ "invalid_argument"
    end
  end

  describe "AG-12 the responder set is the producer's" do
    test "AG-12: a tier that adds a responder outside the waitpoint's responders opens nothing",
         ctx do
      tiers = [tier(@minute, add: [ctx.second])]

      assert ["responder_outside_set", nil] = check([ctx.first], tiers: tiers)
      assert ["ok", "inline"] = check([ctx.first, ctx.second], tiers: tiers)

      opts = [waiter_ref: ctx.agent, responder_ids: [ctx.first]]
      ["opened", id, _, nil] = open(ctx.s, [{:escalation_policy_ref, "inline"} | opts])

      assert error_message(@pin, [id | plan(tiers: tiers)]) =~ "invalid_argument"
      assert steps(id) == []
      assert invitations(id) == []
    end

    test "AG-12: escalation never adds a responder; the set stays as it was opened", ctx do
      id = question(ctx, [tier(@minute, add: [ctx.second])])
      before = rows(@responders, [id])

      advance!(@minute + 1)
      assert ["fired", 1, nil] = run(id)

      assert rows(@responders, [id]) == before
      assert length(before) == 2
      assert Enum.all?(before, fn [_id, added_by] -> added_by == "creation" end)
    end

    test "AG-12: an invitation to a recipient outside the responders cannot be stored" do
      as_owner(&scenario/0, fn ctx ->
        outsider = member!(ctx.s, "subscriber")
        id = question(ctx, [tier(@minute)], responders: [ctx.first])
        error = sql_error(@invite, [ctx.s.tenant, id(), id, outsider])

        assert error.postgres.code == :foreign_key_violation
      end)
    end
  end

  describe "AG-19 one timer and the stop rules" do
    test "AG-19: the waitpoint's timer names the nearest tier and runs it when it is due", ctx do
      tiers = [tier(@minute, add: [ctx.second]), tier(2 * @minute, channels: ["sms"])]
      id = question(ctx, tiers)
      expires = waitpoint(id, "expires_at")
      first_due = DateTime.add(waitpoint(id, "opened_at"), @minute, :millisecond)
      first = ctx.first
      second = ctx.second

      assert waitpoint(id, "next_escalation_at") == first_due
      assert [[^first, "creation", nil, true, "requested", nil]] = invitations(id)
      assert ["not_due", ^first_due] = timer(id)
      assert ["not_due", 0, ^first_due] = run(id)

      advance!(@minute + 1)
      assert ["escalation_due", ^expires] = timer(id)
      assert ["fired", 1, second_due] = run(id)
      assert DateTime.diff(second_due, first_due, :millisecond) == 2 * @minute + 1
      assert waitpoint(id, "next_escalation_at") == second_due
      assert steps(id) == [[1, "fired", nil], [2, "armed", nil]]
      assert [_, [^second, "escalation", nil, true, "requested", nil]] = invitations(id)
      assert List.last(events(id)) == "waitpoint.escalated"
      assert rows(@levels, ["waitpoint:" <> text(id)]) == [[1]]

      advance!(2 * @minute)
      assert ["fired", 1, nil] = run(id)
      assert waitpoint(id, "next_escalation_at") == nil
      assert steps(id) == [[1, "fired", nil], [2, "fired", nil]]

      assert [_, _, third, fourth] = invitations(id)
      assert [_, "escalation", sms, false, "requested", nil] = third
      assert [_, "escalation", ^sms, false, "requested", nil] = fourth
      assert sms == [%{"channel" => "sms"}]
      assert Enum.sort([hd(third), hd(fourth)]) == Enum.sort([first, second])
      assert ["not_due", ^expires] = timer(id)
    end

    test "AG-17: a repeated tier runs again at the same interval and keeps its level", ctx do
      id = question(ctx, [tier(@minute, repeat: 2)], responders: [ctx.first])
      assert steps(id) == [[1, "armed", nil], [1, "pending", nil], [1, "pending", nil]]

      advance!(@minute)
      assert ["fired", 1, %DateTime{}] = run(id)
      advance!(@minute)
      assert ["fired", 1, %DateTime{}] = run(id)
      advance!(@minute)
      assert ["fired", 1, nil] = run(id)
      assert length(invitations(id)) == 4
    end

    test "AG-17: a tier with nobody to invite is skipped, recorded and followed by the next",
         ctx do
      tiers = [tier(@minute), tier(@minute, add: [ctx.first])]
      id = question(ctx, tiers, responders: [ctx.first])
      assert invitations(id) == []

      advance!(@minute)
      assert ["fired", 1, %DateTime{}] = run(id)
      skipped = [1, "skipped", "waitpoint.escalation_tier_skipped"]
      assert steps(id) == [skipped, [2, "armed", nil]]
      refute "waitpoint.escalated" in events(id)

      advance!(@minute)
      assert ["fired", 1, nil] = run(id)
      assert [[_, "escalation", nil, true, "requested", nil]] = invitations(id)
      assert List.last(events(id)) == "waitpoint.escalated"
    end

    test "AG-19, INV-35: a response cancels pending tiers and undelivered invitations only",
         ctx do
      tiers = [tier(@minute, add: [ctx.second]), tier(2 * @minute, channels: ["sms"])]
      id = question(ctx, tiers)
      assert ["settled", _] = settle(invitation(id, ctx.first), "delivered")

      advance!(@minute)
      assert ["fired", 1, %DateTime{}] = run(id)
      assert ["resolved", _response] = answer(ctx, id)

      assert steps(id) == [[1, "fired", nil], [2, "cancelled", "waitpoint.step_cancelled"]]
      assert waitpoint(id, "next_escalation_at") == nil
      first = ctx.first
      second = ctx.second
      cancelled = "waitpoint.invitation_cancelled"

      assert [delivered, undelivered] = invitations(id)
      assert [^first, "creation", nil, true, "delivered", nil] = delivered
      assert [^second, "escalation", nil, true, "cancelled", ^cancelled] = undelivered

      assert ["not_open", 0, nil] = run(id)
      assert ["already_settled", nil] = settle(invitation(id, ctx.second), "delivered")
      assert ["already_terminal", nil] = timer(id)
    end

    test "AG-19, AG-3: a cancellation cancels the pending tiers and compensates nothing", ctx do
      id = question(ctx, [tier(@minute), tier(@minute)], responders: [ctx.first])

      assert cancel(id) == "cancelled"

      cancelled = "waitpoint.step_cancelled"
      assert steps(id) == [[1, "cancelled", cancelled], [2, "cancelled", cancelled]]

      assert [[_, "creation", nil, true, "cancelled", rule]] = invitations(id)
      assert rule == "waitpoint.invitation_cancelled"
      assert one(@audit_count, [text(id)]) == 1
      assert one(@responses, [id]) == 0
      assert events(id) == ["waitpoint.created", "waitpoint.cancelled"]
      assert ["not_open", 0, nil] = run(id)
    end

    test "AG-19, AG-10: a stalled waitpoint suspends its tier and a heartbeat resumes it there",
         ctx do
      opts = [responders: [ctx.first], heartbeat_interval_ms: 30_000]
      id = question(ctx, [tier(@minute), tier(@minute)], opts)

      advance!(31_000)
      assert ["stalled", _expires] = timer(id)
      suspended = "waitpoint.step_suspended"

      assert rows(@suspended, [id]) == [
               [1, "suspended", 29_000, suspended],
               [2, "pending", nil, nil]
             ]

      assert waitpoint(id, "next_escalation_at") == nil
      advance!(10 * @minute)
      assert ["not_open", 0, nil] = run(id)
      assert steps(id) == [[1, "suspended", suspended], [2, "pending", nil]]

      assert ["reopened", %DateTime{}] = row(@heartbeat, [id, ctx.agent])

      resumed = waitpoint(id, "next_escalation_at")
      assert DateTime.diff(resumed, business_now(), :millisecond) == 29_000
      assert steps(id) == [[1, "armed", nil], [2, "pending", nil]]
      assert ["not_due", 0, ^resumed] = run(id)

      advance!(29_500)
      assert ["escalation_due", _] = timer(id)
      assert ["fired", 1, %DateTime{}] = run(id)
      assert steps(id) == [[1, "fired", nil], [2, "armed", nil]]
    end
  end

  describe "AG-18 WF-24 the last tier is only an event" do
    test "AG-18, WF-24: after the last tier only waitpoint.expired comes, with the default",
         ctx do
      opts = [responders: [ctx.first], default_response_ct: "fallback"]
      id = question(ctx, [tier(@minute)], opts)
      mailbox = waitpoint(id, "waiter_mailbox_id")

      advance!(@minute)
      assert ["fired", 1, nil] = run(id)
      assert ["not_due", 0, nil] = run(id)
      assert waitpoint(id, "state") == "open"

      advance!(3_600_000)
      assert ["expired", nil] = timer(id)
      assert events(id) == ["waitpoint.created", "waitpoint.escalated", "waitpoint.expired"]
      assert row(@expired, [mailbox]) == ["fallback", ctx.s.data_key]

      assert waitpoint(id, "state") == "expired"
      assert waitpoint(id, "resolution_response_id") == nil
      assert waitpoint(id, "resolved_at") == nil
      assert one(@responses, [id]) == 0
      assert ["rejected_closed", nil] = answer(ctx, id)
    end

    test "AG-19, WF-25: a tier that falls after the deadline never fires", ctx do
      opts = [responders: [ctx.first], expires_at: {:in, 90_000}]
      id = question(ctx, [tier(@minute, repeat: 1)], opts)
      expires = waitpoint(id, "expires_at")

      advance!(@minute)
      assert ["fired", 1, due] = run(id)
      assert DateTime.compare(due, expires) == :gt

      advance!(31_000)
      assert ["not_open", 0, nil] = run(id)
      assert ["expired", nil] = timer(id)
      assert waitpoint(id, "expires_at") == expires
      assert steps(id) == [[1, "fired", nil], [1, "cancelled", "waitpoint.step_cancelled"]]
    end

    test "AG-19: a cancelled tier never runs again; a closed waitpoint takes no invitation" do
      as_owner(&scenario/0, fn ctx ->
        id = question(ctx, [tier(@minute), tier(@minute)], responders: [ctx.first])
        "cancelled" = cancel(id)

        assert error_message(@revive, [id]) =~ "invariant_violation"

        refused = error_message(@invite, [ctx.s.tenant, id(), id, ctx.first])
        assert refused =~ "invariant_violation"
      end)
    end
  end
end
