defmodule Relay.Agents.WaitpointTimerTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  alias Relay.Agents.Waitpoint
  alias Relay.Agents.WaitpointTimer
  alias RelayTest.TenantFixture

  setup do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    %{s: s, agent: agent, responder: responder, value_key: content_key!(s, responder)}
  end

  defp question(ctx, opts \\ []) do
    ["opened", id, _, nil] =
      open(ctx.s, Keyword.merge([waiter_ref: ctx.agent, responder_ids: [ctx.responder]], opts))

    id
  end

  defp fire(id), do: row("SELECT * FROM relay_fn.waitpoint_timer_fire($1)", [id])

  defp due, do: "SELECT waitpoint_id FROM relay_fn.waitpoint_due(10)" |> rows() |> List.flatten()

  defp answer(ctx, id),
    do:
      respond(id,
        responder_recipient_id: ctx.responder,
        subject_digest: waitpoint(id, "subject_digest"),
        value_key_id: ctx.value_key
      )

  describe "AG-15 T-24 one timer for deadline and heartbeat" do
    test "AG-15: an early wake-up finds nothing due and names the nearest timer", ctx do
      id = question(ctx, heartbeat_interval_ms: 60_000)
      heartbeat = waitpoint(id, "heartbeat_due_at")

      assert ["not_due", ^heartbeat] = fire(id)
      assert waitpoint(id, "state") == "open"

      plain = question(ctx)
      expires = waitpoint(plain, "expires_at")
      assert ["not_due", ^expires] = fire(plain)
      assert ["not_found", nil] = fire(id())
    end

    test "AG-10: a missed heartbeat stalls the waitpoint once and a heartbeat reopens it", ctx do
      id = question(ctx, heartbeat_interval_ms: 1_000)
      expires = waitpoint(id, "expires_at")
      advance!(1_500)

      assert ["stalled", ^expires] = fire(id)
      assert waitpoint(id, "state") == "stalled"
      assert ["not_due", ^expires] = fire(id)
      assert List.last(mailbox_events(waitpoint(id, "waiter_mailbox_id"))) == "waitpoint.stalled"

      assert ["reopened", %DateTime{}] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, ctx.agent])

      assert waitpoint(id, "state") == "open"
    end

    test "AG-9: the deadline expires the waitpoint with its default response", ctx do
      id = question(ctx, default_response_ct: "fallback")
      mailbox = waitpoint(id, "waiter_mailbox_id")
      before = one("SELECT open_count FROM relay.waitpoint_counters")
      advance!(3_600_001)

      assert ["expired", nil] = fire(id)
      assert waitpoint(id, "state") == "expired"
      assert ["already_terminal", nil] = fire(id)
      assert one("SELECT open_count FROM relay.waitpoint_counters") == before - 1

      assert row(
               "SELECT payload_ct, payload_tenant_key_id FROM relay.mailbox_records WHERE mailbox_id = $1 AND event_type = 'waitpoint.expired'",
               [mailbox]
             ) == ["fallback", ctx.s.data_key]

      assert ["rejected_closed", nil] = answer(ctx, id)
    end

    test "AG-11: an answer after the deadline is rejected and expires the waitpoint", ctx do
      id = question(ctx)
      advance!(3_600_001)

      assert ["rejected_expired", nil] = answer(ctx, id)
      assert waitpoint(id, "state") == "expired"

      assert ["already_terminal", nil] =
               row("SELECT * FROM relay_fn.waitpoint_heartbeat($1, 'agent', $2)", [id, ctx.agent])
    end

    test "T-24: the due list follows business time", ctx do
      beating = question(ctx, heartbeat_interval_ms: 1_000)
      plain = question(ctx)
      assert due() == []

      advance!(1_500)
      assert due() == [beating]
      ["stalled", _] = fire(beating)
      assert due() == []

      advance!(3_600_000)
      assert Enum.sort(due()) == Enum.sort([beating, plain])
    end
  end

  describe "WF-43 AG-4 a wait is a row and one short timer job" do
    defp relay_workers do
      {:ok, modules} = :application.get_key(:relay, :modules)

      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__relay_worker__, 0),
          do: module
    end

    defp timer_jobs(waitpoint_id) do
      Relay.Repo.query!(
        "SELECT state, scheduled_at FROM relay_queue.oban_jobs WHERE worker = 'Relay.Agents.WaitpointTimer' AND args->>'waitpoint_id' = $1 ORDER BY id",
        [Relay.Id.to_string(waitpoint_id)]
      ).rows
    end

    defp agent_waitpoint do
      TenantFixture.as_role("relay_worker")
      tenant = TenantFixture.tenant!()
      agent = TenantFixture.recipient!(tenant.test, %{}, kind: :agent)
      expires_at = DateTime.add(Relay.Clock.business_now(tenant.test), 7, :day)

      {:ok, %{result: :opened, waitpoint_id: id}} =
        Waitpoint.open(tenant.test, %{
          id: Relay.Id.generate(),
          kind: :event,
          waiter_kind: :agent,
          waiter_ref: agent,
          match_event_type: "order.paid",
          correlation_key: "wf43-" <> TenantFixture.random(),
          expires_at: expires_at
        })

      {tenant.test, id, expires_at}
    end

    test "WF-43: no job runs longer than one hour and the waitpoint timer runs at most a second" do
      workers = relay_workers()
      assert WaitpointTimer in workers
      assert Relay.Worker.max_timeout_ms() == 3_600_000

      for worker <- workers,
          do:
            assert(worker.timeout(%Oban.Job{}) <= Relay.Worker.max_timeout_ms(), inspect(worker))

      assert WaitpointTimer.timeout(%Oban.Job{}) == 1_000
      assert_raise ArgumentError, fn -> Relay.Worker.validate_timeout!(3_600_001) end
    end

    test "WF-43: a week-long wait is one job scheduled at the deadline, not a running one" do
      {_scope, id, expires_at} = agent_waitpoint()

      assert [["scheduled", at]] = timer_jobs(id)
      assert DateTime.diff(DateTime.from_naive!(at, "Etc/UTC"), expires_at, :millisecond) == 0
    end

    test "AG-4: an open wait holds no queue slot and no process, and an early wake-up ends at once" do
      {scope, id, _expires_at} = agent_waitpoint()

      refute Enum.any?(timer_jobs(id), fn [state, _] -> state in ["executing", "available"] end)

      args =
        scope
        |> Relay.Scope.to_job_args()
        |> Map.put("waitpoint_id", Relay.Id.to_string(id))

      {micros, :ok} = :timer.tc(fn -> WaitpointTimer.perform(%Oban.Job{args: args}) end)
      assert micros < 1_000_000
      assert {:ok, %{state: "open"}} = Waitpoint.get(scope, id)
      assert Enum.all?(timer_jobs(id), fn [state, _] -> state == "scheduled" end)
    end
  end
end
