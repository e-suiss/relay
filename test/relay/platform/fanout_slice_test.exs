defmodule Relay.Platform.FanoutSliceTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.Fanout
  alias Relay.Platform.FanoutSlice
  alias Relay.Repo
  alias RelayTest.TenantFixture

  defmodule ListSource do
    @moduledoc false
    @behaviour Relay.Platform.FanoutSource

    @impl true
    def page(_scope, fanout, position, range_to, limit) do
      {__MODULE__, fanout.source_id}
      |> :persistent_term.get()
      |> Enum.filter(&from?(&1, position))
      |> Enum.filter(&(range_to == nil or &1 < range_to))
      |> Enum.take(limit)
    end

    @impl true
    def process(_scope, _fanout, ids) do
      case Process.get(:fail_on) do
        id when is_binary(id) ->
          if id in ids do
            Process.delete(:fail_on)
            raise "sub-batch failed"
          end

        _ ->
          :ok
      end

      send(self(), {:processed, ids})
      {length(ids), 0}
    end

    defp from?(id, {:after, last}), do: id > last
    defp from?(_id, {:from, nil}), do: true
    defp from?(id, {:from, first}), do: id >= first
  end

  setup do
    previous = Application.get_env(:relay, Fanout)
    Application.put_env(:relay, Fanout, sources: %{"list" => ListSource})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:relay, Fanout, previous),
        else: Application.delete_env(:relay, Fanout)
    end)

    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    source = Relay.Id.generate()
    ids = for ms <- 1..1_000, do: Relay.Id.build(ms, :crypto.strong_rand_bytes(10))
    :persistent_term.put({ListSource, source}, ids)
    on_exit(fn -> :persistent_term.erase({ListSource, source}) end)

    %{scope: tenant.live, source: source, ids: ids}
  end

  defp create!(ctx, opts \\ []) do
    id = Relay.Id.generate()

    {:ok, {:created, ^id, total}} =
      Fanout.create(ctx.scope, %{
        id: id,
        source_kind: "list",
        source_id: ctx.source,
        lane: Keyword.get(opts, :lane, :l1),
        bounds: [nil, Enum.at(ctx.ids, 400), nil],
        recipient_count: length(ctx.ids),
        slice_size: 600,
        sub_batch_size: 100
      })

    {id, total}
  end

  defp jobs(fanout) do
    Repo.query!(
      "SELECT args, queue, priority FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>'fanout_id' = $2 ORDER BY (args->>'slice_no')::int",
      ["Relay.Platform.FanoutSlice", Relay.Id.to_string(fanout)]
    ).rows
  end

  defp perform(args, attempt \\ 1),
    do: FanoutSlice.perform(%Oban.Job{args: args, attempt: attempt, max_attempts: 5})

  defp progress(ctx, fanout) do
    {:ok, progress} = Fanout.get(ctx.scope, fanout)
    progress
  end

  describe "T-23 TN-54 slice jobs" do
    test "T-23: one job per slice carries only its range and the first slice goes first", ctx do
      {fanout, 2} = create!(ctx)

      assert [[first, "l1", 5], [second, "l1", 6]] = jobs(fanout)
      assert first["slice_no"] == 0 and first["range_from"] == nil
      assert second["slice_no"] == 1
      assert second["range_from"] == Relay.Id.to_string(Enum.at(ctx.ids, 400))
      refute Map.has_key?(first, "recipients")

      assert {:ok, {:exists, ^fanout, 2}} =
               Fanout.create(ctx.scope, %{
                 id: Relay.Id.generate(),
                 source_kind: "list",
                 source_id: ctx.source,
                 lane: :l1,
                 bounds: [nil, nil],
                 mode: :bulk
               })

      assert length(jobs(fanout)) == 2
    end

    test "T-23: the slices process every recipient once in sub-batches and close the fan-out",
         ctx do
      {fanout, 2} = create!(ctx)

      for [args, _, _] <- jobs(fanout), do: assert(perform(args) == :ok)

      processed = collect([])
      assert Enum.all?(processed, &(length(&1) <= 100))
      assert List.flatten(processed) == ctx.ids

      assert %{state: "completed", processed_count: 1_000, slices_completed: 2} =
               progress(ctx, fanout)
    end

    test "T-23: a retried slice continues after its checkpoint", ctx do
      {fanout, 2} = create!(ctx)
      [[first, _, _], _] = jobs(fanout)

      Process.put(:fail_on, Enum.at(ctx.ids, 250))
      assert_raise RuntimeError, fn -> perform(first) end
      before = collect([])
      assert List.flatten(before) == Enum.slice(ctx.ids, 0, 200)

      assert perform(first, 2) == :ok
      assert List.flatten(collect([])) == Enum.slice(ctx.ids, 200, 200)

      assert %{processed_count: 400, slices_completed: 1, state: "running"} =
               progress(ctx, fanout)
    end

    test "T-23: a slice whose last attempt fails ends failed and the fan-out closes partial",
         ctx do
      {fanout, 2} = create!(ctx)
      [[first, _, _], [second, _, _]] = jobs(fanout)

      Process.put(:fail_on, Enum.at(ctx.ids, 50))
      assert_raise RuntimeError, fn -> perform(first, 5) end
      assert perform(second) == :ok
      assert %{state: "partial", slices_failed: 1, slices_completed: 1} = progress(ctx, fanout)
    end

    test "T-34: a paused fan-out snoozes its slices and resumes them", ctx do
      {fanout, 2} = create!(ctx)
      [[first, _, _], _] = jobs(fanout)

      assert {:ok, :paused} = Fanout.pause(ctx.scope, fanout, "kill_switch.tenant")
      assert perform(first) == {:snooze, 60}
      assert {:ok, :resumed} = Fanout.resume(ctx.scope, fanout)
      assert perform(first) == :ok
    end

    test "T-23: a slice job with broken arguments is discarded", ctx do
      {fanout, 2} = create!(ctx)
      [[first, _, _], _] = jobs(fanout)

      assert perform(Map.put(first, "fanout_id", "nope")) == {:discard, :invalid_args}
      assert perform(Map.put(first, "slice_no", -1)) == {:discard, :invalid_args}
    end
  end

  describe "T-23 (4) T-32 bulk lanes" do
    test "T-32: bulk lane slices wait in the tenant's DRR table, not in the queue", ctx do
      {fanout, 2} = create!(ctx, lane: :l2)
      assert jobs(fanout) == []
    end

    test "T-23: a cancelled fan-out stops a running slice before its next sub-batch", ctx do
      {fanout, 2} = create!(ctx)
      [[first, _, _], [second, _, _]] = jobs(fanout)

      assert {:ok, {:cancelled, 2}} =
               Fanout.cancel(
                 ctx.scope,
                 fanout,
                 "operator.cancel",
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert perform(first) == :ok
      assert perform(second) == :ok
      assert collect([]) == []
      assert %{state: "cancelled", slices_cancelled: 2} = progress(ctx, fanout)
    end
  end

  defp collect(acc) do
    receive do
      {:processed, ids} -> collect([ids | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
