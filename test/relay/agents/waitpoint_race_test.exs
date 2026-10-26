defmodule Relay.Agents.WaitpointRaceTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Agents.Waitpoint
  alias Relay.Platform.VirtualClock
  alias Relay.Platform.VirtualClock.Tick
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @pairs 1_000

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp event_waitpoint(scope, agent, key, opts \\ []) do
    expires_at =
      DateTime.add(
        Relay.Clock.business_now(scope),
        Keyword.get(opts, :in_ms, 3_600_000),
        :millisecond
      )

    Waitpoint.open(scope, %{
      id: Relay.Id.generate(),
      kind: :event,
      waiter_kind: :agent,
      waiter_ref: agent,
      match_event_type: "order.paid",
      correlation_key: key,
      expires_at: expires_at
    })
  end

  defp event(agent, key) do
    %{
      event_id: Relay.Id.generate(),
      event_type: "order.paid",
      correlation_key: key,
      waiter_kind: :agent,
      waiter_ref: agent,
      payload_digest: TenantFixture.digest()
    }
  end

  defp scalar(scope, sql, params) do
    {:ok, [[value]]} =
      unboxed(fn -> Repo.in_scope(scope, fn _ -> Repo.scoped_query!(sql, params).rows end) end)

    value
  end

  defp timer_at(waitpoint_id) do
    %{rows: [[at]]} =
      Repo.query!(
        "SELECT scheduled_at FROM relay_queue.oban_jobs WHERE worker = 'Relay.Agents.WaitpointTimer' AND args->>'waitpoint_id' = $1 ORDER BY id DESC LIMIT 1",
        [Relay.Id.to_string(waitpoint_id)]
      )

    DateTime.from_naive!(at, "Etc/UTC")
  end

  defp tick!(scope) do
    %{rows: [[args]]} =
      Repo.query!(
        "SELECT args FROM relay_queue.oban_jobs WHERE worker = 'Relay.Platform.VirtualClock.Tick' AND args->>'tenant_id' = $1 ORDER BY id DESC LIMIT 1",
        [Relay.Id.to_string(scope.tenant_id)]
      )

    Tick.perform(%Oban.Job{args: args})
  end

  describe "T-61 AG-13 AG-14 waitpoints racing their events on the real engine" do
    @tag timeout: 300_000
    test "AG-13: 1000 waitpoints opened against their events each resolve exactly once" do
      {scope, agent} =
        unboxed(fn ->
          tenant = TenantFixture.tenant!()
          {tenant.test, TenantFixture.recipient!(tenant.test, %{}, kind: :agent)}
        end)

      prefix = "race-" <> TenantFixture.random() <> "-"

      work =
        Enum.flat_map(1..@pairs, fn n ->
          key = prefix <> Integer.to_string(n)

          if rem(n, 2) == 0,
            do: [{:open, key}, {:offer, key}],
            else: [{:offer, key}, {:open, key}]
        end)

      results =
        work
        |> Task.async_stream(
          fn
            {:open, key} ->
              {:open, unboxed(fn -> event_waitpoint(scope, agent, key) end)}

            {:offer, key} ->
              {:offer, unboxed(fn -> Waitpoint.offer_event(scope, event(agent, key)) end)}
          end,
          max_concurrency: 16,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      opens = for {:open, {:ok, opened}} <- results, do: opened
      offers = for {:offer, {:ok, offered}} <- results, do: offered
      assert length(opens) == @pairs and length(offers) == @pairs
      assert Enum.all?(opens, &(&1.result == :opened))

      early = Enum.count(opens, &match?({:resolved_by_event, :resolved}, &1.early))
      matched = Enum.count(offers, &(&1.result == :matched))
      assert early + matched == @pairs
      assert Enum.count(offers, &(&1.result == :buffered)) == early
      refute Enum.any?(offers, &(&1.result == :unmatched))

      like = prefix <> "%"

      assert scalar(
               scope,
               "SELECT count(*) FROM relay.waitpoints WHERE correlation_key LIKE $1 AND state = 'resolved'",
               [like]
             ) == @pairs

      assert scalar(
               scope,
               "SELECT count(*) FROM relay.mailbox_records WHERE kind = 'early_event' AND correlation_key LIKE $1 AND consumed_at IS NULL",
               [like]
             ) == 0

      assert scalar(scope, "SELECT open_count FROM relay.waitpoint_counters", []) == 0
    end
  end

  describe "T-61 (3) TN-8 T-24 virtual clock flow" do
    setup do
      TenantFixture.as_role("relay_worker")
      tenant = TenantFixture.tenant!()
      agent = TenantFixture.recipient!(tenant.test, %{}, kind: :agent)
      %{tenant: tenant, scope: tenant.test, agent: agent}
    end

    test "TN-8: a step of the virtual clock runs the waitpoint deadlines that fell due", ctx do
      {:ok, %{result: :opened, waitpoint_id: id, expires_at: expires_at}} =
        event_waitpoint(ctx.scope, ctx.agent, "flow-1")

      assert DateTime.diff(timer_at(id), expires_at, :millisecond) == 0

      assert {:ok, {:advanced, 1_800_000, _}} =
               VirtualClock.advance(
                 ctx.scope,
                 1_800_000,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert :ok = tick!(ctx.scope)
      assert {:ok, %{state: "open"}} = Waitpoint.get(ctx.scope, id)

      {:ok, %{waitpoint_id: later, expires_at: later_expires}} =
        event_waitpoint(ctx.scope, ctx.agent, "flow-2")

      assert DateTime.diff(later_expires, timer_at(later), :millisecond) == 1_800_000

      assert {:ok, {:advanced, 3_660_000, _}} =
               VirtualClock.advance(
                 ctx.scope,
                 1_860_000,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert :ok = tick!(ctx.scope)
      assert {:ok, %{state: "expired"}} = Waitpoint.get(ctx.scope, id)
      assert {:ok, %{state: "open"}} = Waitpoint.get(ctx.scope, later)
    end

    test "X-27: business time moves only in test", ctx do
      assert {:ok, :not_test_environment} =
               VirtualClock.advance(
                 ctx.tenant.live,
                 60_000,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert {:ok, :not_test_environment} = VirtualClock.get(ctx.tenant.live)

      {:ok, {:advanced, 86_400_000, _}} =
        VirtualClock.advance(ctx.scope, 86_400_000, TenantFixture.digest(), TenantFixture.actor())

      assert {:ok, {:ok, 86_400_000, _}} = VirtualClock.get(ctx.scope)

      live = Relay.Clock.business_now(ctx.tenant.live)
      test = Relay.Clock.business_now(ctx.scope)
      assert_in_delta DateTime.diff(test, live, :millisecond), 86_400_000, 5_000
      assert Relay.Clock.wall_time(ctx.tenant.live, live) == live

      assert DateTime.diff(test, Relay.Clock.wall_time(ctx.scope, test), :millisecond) ==
               86_400_000
    end
  end
end
