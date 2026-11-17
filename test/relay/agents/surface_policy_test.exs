defmodule Relay.Agents.SurfacePolicyTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  @minute 60_000
  @skipped "waitpoint.surface_step_skipped"

  @check "SELECT * FROM relay_fn.waitpoint_plan_check($1, $2, $3, $4, $5, $6)"
  @pin "SELECT * FROM relay_fn.waitpoint_plan_pin($1, $2, $3, $4, $5, $6)"
  @settle "SELECT * FROM relay_fn.waitpoint_invitation_settle($1, $2)"
  @heartbeat "SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)"
  @register "SELECT * FROM relay_fn.device_register($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)"
  @steps "SELECT ordinal, state, rule_id FROM relay.waitpoint_steps WHERE waitpoint_id = $1 AND track = 'surface' AND recipient_id = $2 ORDER BY ordinal"
  @any_steps "SELECT count(*) FROM relay.waitpoint_steps WHERE waitpoint_id = $1"
  @remaining "SELECT ordinal, state, remaining_ms FROM relay.waitpoint_steps WHERE waitpoint_id = $1 AND state IN ('armed', 'suspended')"
  @invitations "SELECT source, surfaces, inbox, state, rule_id FROM relay.waitpoint_invitations WHERE waitpoint_id = $1 AND recipient_id = $2 ORDER BY id"
  @invitation_ids "SELECT id FROM relay.waitpoint_invitations WHERE waitpoint_id = $1 AND recipient_id = $2 ORDER BY id"
  @all_invitations "SELECT count(*) FROM relay.waitpoint_invitations WHERE waitpoint_id = $1"

  setup do
    s = setup!()
    agent = member!(s, "agent")
    first = member!(s, "subscriber")
    second = member!(s, "subscriber")

    %{s: s, agent: agent, first: first, second: second, value_key: content_key!(s, first)}
  end

  defp text(id), do: Relay.Id.to_string(id)

  defp device!(ctx, recipient, permission \\ "granted") do
    token = [digest()]
    head = [id(), recipient, "fcm", "com.example.app", token, ctx.s.bidx_key, "token", nil]
    ["created", device] = row(@register, head ++ [permission, [], "en", [], 20])
    device
  end

  defp device(id), do: %{"device_id" => text(id)}
  defp channel(name), do: %{"channel" => name}
  defp step(surfaces, after_ms), do: %{"surfaces" => surfaces, "escalate_after_ms" => after_ms}

  defp policy(recipient, steps),
    do: %{"recipient_id" => text(recipient), "kind" => "subscriber", "steps" => steps}

  defp plan(opts),
    do: [opts[:key], opts[:version], opts[:tiers], opts[:surface], Keyword.get(opts, :max, 10)]

  defp check(responders, opts), do: row(@check, [responders | plan(opts)])

  defp question(ctx, surface, opts \\ []) do
    {tiers, opts} = Keyword.pop(opts, :tiers)
    reference = if tiers, do: "inline"
    responders = [ctx.first, ctx.second]

    base = [
      waiter_ref: ctx.agent,
      responder_ids: responders,
      surface_policy: surface,
      escalation_policy_ref: reference
    ]

    ["opened", id, _, nil] = open(ctx.s, Keyword.merge(base, opts))
    ["pinned", _next] = row(@pin, [id | plan(tiers: tiers, surface: surface)])
    id
  end

  defp timer(id), do: row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [id])
  defp run(id), do: row("SELECT * FROM relay_fn.waitpoint_steps_fire($1)", [id])
  defp steps(id, recipient), do: rows(@steps, [id, recipient])
  defp invitations(id, recipient), do: rows(@invitations, [id, recipient])
  defp invitation_ids(id, recipient), do: List.flatten(rows(@invitation_ids, [id, recipient]))
  defp settle(invitation_id, outcome), do: row(@settle, [invitation_id, outcome])
  defp events(id), do: mailbox_events(waitpoint(id, "waiter_mailbox_id"))

  defp answer(ctx, id) do
    digest = waitpoint(id, "subject_digest")
    opts = [responder_recipient_id: ctx.first, value_key_id: ctx.value_key]
    respond(id, [{:subject_digest, digest} | opts])
  end

  describe "AG-63 sender surface policy" do
    test "AG-63: the first step is invited at once, the next when its time passes, the rest last",
         ctx do
      phone = device!(ctx, ctx.first)
      steps = [step([device(phone)], 2 * @minute), step([channel("sms")], 5 * @minute)]
      id = question(ctx, [policy(ctx.first, steps)])
      first_due = DateTime.add(waitpoint(id, "opened_at"), 2 * @minute, :millisecond)

      assert invitations(id, ctx.first) == [
               ["surface", [device(phone)], true, "requested", nil]
             ]

      assert steps(id, ctx.first) == [[1, "fired", nil], [2, "armed", nil], [3, "pending", nil]]
      assert waitpoint(id, "next_escalation_at") == first_due
      assert ["not_due", ^first_due] = timer(id)
      assert ["not_due", 0, ^first_due] = run(id)

      advance!(2 * @minute)
      assert ["escalation_due", _expires] = timer(id)
      assert ["fired", 1, second_due] = run(id)
      assert DateTime.diff(second_due, first_due, :millisecond) == 5 * @minute
      assert [_, ["surface", sms, false, "requested", nil]] = invitations(id, ctx.first)
      assert sms == [channel("sms")]

      advance!(5 * @minute)
      assert ["fired", 1, nil] = run(id)
      assert [_, _, ["surface", rest, false, "requested", nil]] = invitations(id, ctx.first)
      assert rest == %{"except" => [device(phone), channel("sms")]}
      assert steps(id, ctx.first) == [[1, "fired", nil], [2, "fired", nil], [3, "fired", nil]]
      assert waitpoint(id, "next_escalation_at") == nil
      refute "waitpoint.escalated" in events(id)
    end

    test "AG-63, AG-28: a responder without a policy is invited on everything at once", ctx do
      phone = device!(ctx, ctx.first)
      id = question(ctx, [policy(ctx.first, [step([device(phone)], @minute)])])

      assert invitations(id, ctx.second) == [["creation", nil, true, "requested", nil]]
      assert steps(id, ctx.second) == []

      opts = [waiter_ref: ctx.agent, responder_ids: [ctx.first, ctx.second]]
      ["opened", plain, _, nil] = open(ctx.s, opts)
      expires = waitpoint(plain, "expires_at")

      assert one(@any_steps, [plain]) == 0
      assert one(@all_invitations, [plain]) == 0
      assert waitpoint(plain, "next_escalation_at") == nil
      assert ["not_due", ^expires] = timer(plain)
    end

    test "AG-63: a surface that is not registered or not permitted is skipped at once", ctx do
      denied = device!(ctx, ctx.first, "denied")
      foreign = device!(ctx, ctx.second)

      steps = [
        step([device(id())], @minute),
        step([device(denied)], @minute),
        step([device(foreign)], @minute),
        step([device(id()), channel("sms")], @minute)
      ]

      id = question(ctx, [policy(ctx.first, steps)])

      assert steps(id, ctx.first) == [
               [1, "skipped", @skipped],
               [2, "skipped", @skipped],
               [3, "skipped", @skipped],
               [4, "fired", nil],
               [5, "armed", nil]
             ]

      assert invitations(id, ctx.first) == [
               ["surface", [channel("sms")], true, "requested", nil]
             ]

      due = DateTime.add(waitpoint(id, "opened_at"), @minute, :millisecond)
      assert waitpoint(id, "next_escalation_at") == due
    end

    test "AG-63: a surface that fails for good is recorded and the next step is not kept waiting",
         ctx do
      phone = device!(ctx, ctx.first)
      steps = [step([device(phone)], 10 * @minute), step([channel("sms")], 10 * @minute)]
      id = question(ctx, [policy(ctx.first, steps)])
      [first_invitation] = invitation_ids(id, ctx.first)

      assert ["settled", next] = settle(first_invitation, "unreachable")
      assert DateTime.diff(next, business_now(), :millisecond) == 10 * @minute
      assert ["already_settled", ^next] = settle(first_invitation, "delivered")
      assert ["not_found", nil] = settle(id(), "delivered")

      moved = [[1, "skipped", @skipped], [2, "fired", nil], [3, "armed", nil]]
      assert steps(id, ctx.first) == moved

      assert invitations(id, ctx.first) == [
               ["surface", [device(phone)], true, "unreachable", @skipped],
               ["surface", [channel("sms")], false, "requested", nil]
             ]

      [_, second_invitation] = invitation_ids(id, ctx.first)
      assert ["settled", ^next] = settle(second_invitation, "delivered")
      assert steps(id, ctx.first) == moved

      advance!(10 * @minute)
      assert ["fired", 1, nil] = run(id)
      assert length(invitations(id, ctx.first)) == 3
    end

    test "AG-63, AG-19: the first valid response closes every surface and invites nobody after",
         ctx do
      phone = device!(ctx, ctx.first)
      steps = [step([device(phone)], 2 * @minute), step([channel("sms")], 2 * @minute)]
      id = question(ctx, [policy(ctx.first, steps)])

      assert ["resolved", _response] = answer(ctx, id)

      stopped = "waitpoint.step_cancelled"
      closed = [[1, "fired", nil], [2, "cancelled", stopped], [3, "cancelled", stopped]]
      assert steps(id, ctx.first) == closed
      rule = "waitpoint.invitation_cancelled"
      assert [["surface", _phone, true, "cancelled", ^rule]] = invitations(id, ctx.first)
      assert [["creation", nil, true, "cancelled", ^rule]] = invitations(id, ctx.second)
      assert waitpoint(id, "next_escalation_at") == nil

      advance!(30 * @minute)
      assert ["not_open", 0, nil] = run(id)
      assert ["already_terminal", nil] = timer(id)
      assert one(@all_invitations, [id]) == 2
      [late] = invitation_ids(id, ctx.first)
      assert ["already_settled", nil] = settle(late, "unreachable")
      assert one(@all_invitations, [id]) == 2
    end

    test "AG-63, AG-19: the schedule never extends expires_at", ctx do
      phone = device!(ctx, ctx.first)
      steps = [step([device(phone)], @minute), step([channel("sms")], @minute)]
      id = question(ctx, [policy(ctx.first, steps)], expires_at: {:in, 90_000})
      expires = waitpoint(id, "expires_at")

      advance!(@minute)
      assert ["fired", 1, due] = run(id)
      assert DateTime.compare(due, expires) == :gt

      advance!(31_000)
      assert ["not_open", 0, nil] = run(id)
      assert ["expired", nil] = timer(id)
      assert waitpoint(id, "expires_at") == expires
      assert waitpoint(id, "state") == "expired"

      assert steps(id, ctx.first) == [
               [1, "fired", nil],
               [2, "fired", nil],
               [3, "cancelled", "waitpoint.step_cancelled"]
             ]

      assert events(id) == ["waitpoint.created", "waitpoint.expired"]
    end

    test "AG-63, AG-10: a stalled waitpoint suspends the schedule and a heartbeat resumes it",
         ctx do
      phone = device!(ctx, ctx.first)
      steps = [step([device(phone)], @minute), step([channel("sms")], @minute)]
      id = question(ctx, [policy(ctx.first, steps)], heartbeat_interval_ms: 30_000)

      advance!(31_000)
      assert ["stalled", _expires] = timer(id)
      assert rows(@remaining, [id]) == [[2, "suspended", 29_000]]
      assert waitpoint(id, "next_escalation_at") == nil

      advance!(5 * @minute)
      assert ["not_open", 0, nil] = run(id)
      assert length(invitations(id, ctx.first)) == 1

      assert ["reopened", %DateTime{}] = row(@heartbeat, [id, ctx.agent])
      assert rows(@remaining, [id]) == [[2, "armed", nil]]

      advance!(29_000)
      assert ["fired", 1, %DateTime{}] = run(id)
      assert [_, ["surface", sms, false, "requested", nil]] = invitations(id, ctx.first)
      assert sms == [channel("sms")]
    end

    test "AG-63, AG-12: a surface policy names only responders and only interrupting surfaces",
         ctx do
      steps = [step([channel("sms")], @minute)]
      outside = [policy(ctx.second, steps)]
      inbox = [policy(ctx.first, [step([channel("in_app")], @minute)])]
      twice = [policy(ctx.first, steps), policy(ctx.first, steps)]
      undated = [policy(ctx.first, [%{"surfaces" => [channel("sms")]}])]

      assert ["surface_recipient_outside_set", nil] = check([ctx.first], surface: outside)
      assert ["ok", nil] = check([ctx.first, ctx.second], surface: outside)

      for refused <- [inbox, twice, undated] do
        message = error_message(@check, [[ctx.first] | plan(surface: refused)])
        assert message =~ "invalid_argument"
      end
    end

    test "AG-63, AG-17: a responder a tier adds starts its own surface schedule then", ctx do
      phone = device!(ctx, ctx.second)
      steps = [step([device(phone)], 2 * @minute)]
      added = [%{"kind" => "subscriber", "id" => text(ctx.second)}]
      tiers = [%{"after_ms" => @minute, "add_responders" => added, "channels" => ["sms"]}]
      id = question(ctx, [policy(ctx.second, steps)], tiers: tiers)

      assert invitations(id, ctx.second) == []
      assert steps(id, ctx.second) == [[1, "pending", nil], [2, "pending", nil]]
      assert invitations(id, ctx.first) == [["creation", nil, true, "requested", nil]]

      advance!(@minute)
      assert ["fired", 1, due] = run(id)
      assert DateTime.diff(due, business_now(), :millisecond) == 2 * @minute
      assert steps(id, ctx.second) == [[1, "fired", nil], [2, "armed", nil]]

      assert invitations(id, ctx.second) == [
               ["surface", [device(phone)], true, "requested", nil]
             ]

      assert [_, ["escalation", sms, false, "requested", nil]] = invitations(id, ctx.first)
      assert sms == [channel("sms")]
      assert List.last(events(id)) == "waitpoint.escalated"
    end
  end
end
