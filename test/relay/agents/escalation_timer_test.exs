defmodule Relay.Agents.EscalationTimerTest do
  use Relay.DataCase, async: false

  alias Relay.Agents
  alias Relay.Agents.WaitpointTimer
  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @minute 60_000
  @jobs "SELECT scheduled_at FROM relay_queue.oban_jobs WHERE worker = 'Relay.Agents.WaitpointTimer' AND args->>'waitpoint_id' = $1 ORDER BY id DESC LIMIT 1"

  defmodule Sink do
    @moduledoc false

    @spec waitpoint_invitations(Relay.Scope.t(), Relay.Id.t(), [map()]) :: :ok
    def waitpoint_invitations(_scope, waitpoint_id, invitations) do
      send(self(), {:invited, waitpoint_id, invitations})
      :ok
    end
  end

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    previous = Application.get_env(:relay, Relay.Agents, [])
    Application.put_env(:relay, Relay.Agents, Keyword.put(previous, :invitation_sink, Sink))
    on_exit(fn -> Application.put_env(:relay, Relay.Agents, previous) end)

    %{
      scope: scope,
      agent: TenantFixture.recipient!(scope, %{}, kind: :agent),
      first: TenantFixture.recipient!(scope, %{}),
      second: TenantFixture.recipient!(scope, %{}),
      data_key: TenantFixture.keys!(scope).data
    }
  end

  defp text(id), do: Relay.Id.to_string(id)
  defp responder(id), do: %{"kind" => "subscriber", "id" => text(id)}

  defp tier(after_ms, added),
    do: %{"after_ms" => after_ms, "add_responders" => Enum.map(added, &responder/1)}

  defp question(ctx, plan) do
    attrs = %{
      id: Relay.Id.generate(),
      kind: :question,
      waiter_kind: :agent,
      waiter_ref: ctx.agent,
      match_event_type: "agent.answer",
      correlation_key: "esc-" <> TenantFixture.random(),
      response_schema: %{"type" => "object"},
      responder_ids: [ctx.first, ctx.second],
      subject_digest: TenantFixture.digest(),
      content_ct: "content",
      field_key_id: ctx.data_key,
      expires_at: DateTime.add(Relay.Clock.business_now(ctx.scope), 1, :day)
    }

    Agents.open_waitpoint(ctx.scope, Map.merge(attrs, plan))
  end

  defp advance!(scope, ms) do
    {:ok, {:advanced, _total, _version}} =
      VirtualClock.advance(scope, ms, TenantFixture.digest(), TenantFixture.actor())

    :ok
  end

  defp perform(scope, id) do
    args = scope |> Relay.Scope.to_job_args() |> Map.put("waitpoint_id", text(id))
    WaitpointTimer.perform(%Oban.Job{args: args})
  end

  defp timer_at(id) do
    %{rows: [[at]]} = Repo.query!(@jobs, [text(id)])
    DateTime.from_naive!(at, "Etc/UTC")
  end

  defp on_time?(scope, id, business_at) do
    wall = Relay.Clock.wall_time(scope, business_at)
    DateTime.diff(timer_at(id), wall, :millisecond) == 0
  end

  defp states(scope, id) do
    {:ok, steps} = Agents.waitpoint_steps(scope, id)
    Enum.map(steps, & &1["state"])
  end

  describe "AG-19 WF-43 the waitpoint's one timer runs its tiers" do
    test "AG-19, WF-43: a tier is a row that the waitpoint's own timer job runs when due", ctx do
      plan = %{escalation: %{tiers: [tier(@minute, [ctx.second])]}}
      assert {:ok, %{result: :opened, waitpoint_id: id}} = question(ctx, plan)

      first = ctx.first
      assert_received {:invited, ^id, [%{"recipient_id" => ^first, "source" => "creation"}]}

      assert {:ok, %{next_escalation_at: due, escalation_policy_ref: "inline"}} =
               Agents.get_waitpoint(ctx.scope, id)

      assert on_time?(ctx.scope, id, due)
      assert states(ctx.scope, id) == ["armed"]

      assert :ok = perform(ctx.scope, id)
      assert states(ctx.scope, id) == ["armed"]
      refute_received {:invited, ^id, _invitations}

      :ok = advance!(ctx.scope, @minute + 1_000)
      assert :ok = perform(ctx.scope, id)
      assert states(ctx.scope, id) == ["fired"]

      assert_received {:invited, ^id, [_creation, %{"source" => "escalation"} = added]}
      assert added["recipient_id"] == ctx.second
      assert added["state"] == "requested"

      assert {:ok, %{next_escalation_at: nil, state: "open", expires_at: expires}} =
               Agents.get_waitpoint(ctx.scope, id)

      assert on_time?(ctx.scope, id, expires)
    end

    test "AG-10, AG-19: a returning heartbeat gives the resumed tier a timer of its own", ctx do
      plan = %{escalation: %{tiers: [tier(@minute, [])]}, heartbeat_interval_ms: 30_000}
      assert {:ok, %{result: :opened, waitpoint_id: id}} = question(ctx, plan)

      :ok = advance!(ctx.scope, 31_000)
      assert :ok = perform(ctx.scope, id)
      assert {:ok, stalled} = Agents.get_waitpoint(ctx.scope, id)
      assert %{state: "stalled", next_escalation_at: nil} = stalled
      assert states(ctx.scope, id) == ["suspended"]

      :ok = advance!(ctx.scope, 10 * @minute)
      assert {:ok, {:reopened, _due}} = Agents.heartbeat(ctx.scope, id, :agent, ctx.agent)

      assert {:ok, %{state: "open", next_escalation_at: %DateTime{} = resumed}} =
               Agents.get_waitpoint(ctx.scope, id)

      assert DateTime.diff(resumed, Relay.Clock.business_now(ctx.scope), :millisecond) <= 29_000
      assert on_time?(ctx.scope, id, resumed)
      assert states(ctx.scope, id) == ["armed"]
    end
  end

  describe "AG-12 AG-17 AG-63 the plan of a waitpoint" do
    test "AG-12, AG-53: a plan that does not fit the responders opens nothing", ctx do
      outsider = TenantFixture.recipient!(ctx.scope, %{})
      outside = %{escalation: %{tiers: [tier(@minute, [outsider])]}}
      long = %{escalation: %{tiers: List.duplicate(tier(@minute, []), 11)}}
      unknown = %{escalation: %{key: "nobody-wrote-this"}}

      surface = %{
        "recipient_id" => text(outsider),
        "kind" => "subscriber",
        "steps" => [%{"surfaces" => [%{"channel" => "sms"}], "escalate_after_ms" => @minute}]
      }

      refusals = [
        {outside, :escalation_responder_outside_set},
        {long, :escalation_tier_limit},
        {unknown, :escalation_policy_not_found},
        {%{surface_policy: [surface]}, :surface_recipient_outside_set}
      ]

      for {plan, refusal} <- refusals do
        assert {:ok, %{result: ^refusal, waitpoint_id: nil}} = question(ctx, plan)
      end

      assert {:ok, []} = Agents.list_waitpoints(ctx.scope, %{})
      refute_received {:invited, _id, _invitations}
    end

    test "AG-17: a waitpoint pins the latest version of the stored policy it names", ctx do
      write = fn tiers, expected ->
        Repo.in_scope(ctx.scope, fn _status ->
          attrs = %{tiers: tiers, description: "on call"}
          digest = TenantFixture.digest()
          Agents.put_escalation_policy("on-call", attrs, expected, digest, TenantFixture.actor())
        end)
      end

      assert {:ok, {:created, _policy, 1}} = write.([tier(@minute, [])], nil)
      assert {:ok, {:versioned, _policy, 2}} = write.([tier(2 * @minute, [ctx.second])], 1)

      plan = %{escalation: %{key: "on-call"}}
      assert {:ok, %{result: :opened, waitpoint_id: id}} = question(ctx, plan)
      assert {:ok, %{escalation_policy_ref: latest}} = Agents.get_waitpoint(ctx.scope, id)
      assert latest == "on-call:2"

      older = %{escalation: %{key: "on-call", version: 1}}
      assert {:ok, %{result: :opened, waitpoint_id: other}} = question(ctx, older)
      assert {:ok, %{escalation_policy_ref: pinned}} = Agents.get_waitpoint(ctx.scope, other)
      assert pinned == "on-call:1"

      assert {:ok, [%{"after_ms" => 120_000}]} = Agents.waitpoint_steps(ctx.scope, id)
      assert {:ok, [%{"after_ms" => 60_000}]} = Agents.waitpoint_steps(ctx.scope, other)
    end

    test "AG-63: an unreachable surface is settled and the next step is announced at once", ctx do
      steps = [%{"surfaces" => [%{"channel" => "sms"}], "escalate_after_ms" => 5 * @minute}]
      surface = %{"recipient_id" => text(ctx.first), "kind" => "subscriber", "steps" => steps}

      assert {:ok, %{result: :opened, waitpoint_id: id}} =
               question(ctx, %{surface_policy: [surface]})

      assert_received {:invited, ^id, invited}
      assert Enum.sort(Enum.map(invited, & &1["source"])) == ["creation", "surface"]
      sms = Enum.find(invited, &(&1["source"] == "surface"))
      assert sms["surfaces"] == [%{"channel" => "sms"}]
      assert sms["inbox"] == true

      assert {:ok, {:settled, nil}} =
               Agents.settle_invitation(ctx.scope, sms["id"], :unreachable)

      assert_received {:invited, ^id, requested}
      rest = Enum.find(requested, &(&1["source"] == "surface"))
      assert rest["surfaces"] == %{"except" => [%{"channel" => "sms"}]}
      assert rest["inbox"] == false

      assert {:ok, {:already_settled, _next}} =
               Agents.settle_invitation(ctx.scope, sms["id"], :delivered)

      assert {:ok, invitations} = Agents.waitpoint_invitations(ctx.scope, id)
      assert Enum.count(invitations, &(&1["state"] == "unreachable")) == 1
      assert states(ctx.scope, id) == ["skipped", "fired"]
    end
  end
end
