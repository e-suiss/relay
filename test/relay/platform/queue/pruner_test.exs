defmodule Relay.Platform.Queue.PrunerTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.Queue.Pruner
  alias Relay.Platform.Queue.PrunerStore
  alias Relay.QueueRepo
  alias Relay.Repo

  setup do
    owner = Sandbox.start_owner!(QueueRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  defp insert_job(state, finished_at) do
    column =
      case state do
        "completed" -> "completed_at"
        "cancelled" -> "cancelled_at"
        "discarded" -> "discarded_at"
      end

    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[id]]} =
        Repo.query!(
          "INSERT INTO relay_queue.oban_jobs (state, queue, worker, args, #{column}) VALUES ($1, 'pruner_test', 'RelayTest.TenantFixture.SendWorker', '{}', $2) RETURNING id",
          [state, finished_at]
        )

      id
    end)
  end

  defp exists?(id) do
    %{rows: [[found]]} =
      QueueRepo.query!("SELECT count(*) = 1 FROM relay_queue.oban_jobs WHERE id = $1", [id])

    found
  end

  defp visible(tenant) do
    {:ok, rows} =
      QueueRepo.transaction(fn ->
        QueueRepo.query!(
          "SELECT set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true), set_config('relay.environment', 'live', true)"
        )

        QueueRepo.query!(
          "SELECT limit_key FROM relay_queue.limiter_states WHERE tenant_id = $1 UNION ALL SELECT slot_no::text FROM relay_queue.concurrency_slots WHERE tenant_id = $1",
          [tenant]
        ).rows
      end)

    rows
  end

  defp ago(days),
    do: Relay.Clock.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.to_naive()

  describe "OP-12 the queue cleaner" do
    test "OP-12: only completed and cancelled rows past their age are removed, never discarded ones" do
      old_completed = insert_job("completed", ago(2))
      fresh_completed = insert_job("completed", ago(0))
      old_cancelled = insert_job("cancelled", ago(8))
      young_cancelled = insert_job("cancelled", ago(3))
      old_discarded = insert_job("discarded", ago(30))

      {completed, cancelled} = Pruner.cutoffs(Relay.Clock.utc_now(), [])
      assert {:ok, removed} = PrunerStore.prune(completed, cancelled, 100_000)
      assert removed >= 2

      refute exists?(old_completed)
      refute exists?(old_cancelled)
      assert exists?(fresh_completed)
      assert exists?(young_cancelled)
      assert exists?(old_discarded)
    end

    test "OP-12: a run removes at most its limit" do
      for _ <- 1..3, do: insert_job("completed", ago(3))

      {completed, cancelled} = Pruner.cutoffs(Relay.Clock.utc_now(), [])
      assert {:ok, 2} = PrunerStore.prune(completed, cancelled, 2)
    end

    test "OP-74: each run prunes every ephemeral queue table in order and counts its rows" do
      assert {:ok, counts} = PrunerStore.prune_ephemeral(1_000)
      assert Enum.map(counts, &elem(&1, 0)) == PrunerStore.ephemeral_tables()
      assert Enum.all?(counts, fn {_table, count} -> is_integer(count) and count >= 0 end)
    end

    test "OP-74: expired limiter and slot rows go an hour after expiry and live ones stay" do
      admin = Relay.SqlCase.connect(:admin)
      tenant = Relay.Id.generate()

      Relay.SqlCase.on(admin, fn ->
        Relay.SqlCase.rows(
          """
          INSERT INTO relay_queue.limiter_states (tenant_id, environment, limit_key, algorithm,
            win_index, cur_count, prev_count, expires_at, updated_at)
          VALUES ($1, 'test', 'prune.test:old', 'fixed_window', 1, 1, 0, now() - interval '2 hours', now()),
            ($1, 'test', 'prune.test:recent', 'fixed_window', 1, 1, 0, now() - interval '10 minutes', now()),
            ($1, 'test', 'prune.test:live', 'fixed_window', 1, 1, 0, now() + interval '1 hour', now())
          """,
          [tenant]
        )

        Relay.SqlCase.rows(
          """
          INSERT INTO relay_queue.concurrency_slots (tenant_id, environment, counter_key, slot_no,
            expires_at, updated_at)
          VALUES ($1, 'test', 'cc.tenant_deliveries', 1, now() - interval '2 hours', now()),
            ($1, 'test', 'cc.tenant_deliveries', 2, now() + interval '1 day', now())
          """,
          [tenant]
        )
      end)

      try do
        assert visible(tenant) == [["prune.test:old"], ["1"]]
        assert {:ok, counts} = PrunerStore.prune_ephemeral(100_000)
        counts = Map.new(counts)
        assert counts["limiter_states"] >= 1
        assert counts["concurrency_slots"] >= 1
        assert visible(tenant) == []
      after
        Relay.SqlCase.on(admin, fn ->
          Relay.SqlCase.rows("DELETE FROM relay_queue.limiter_states WHERE tenant_id = $1", [
            tenant
          ])

          Relay.SqlCase.rows("DELETE FROM relay_queue.concurrency_slots WHERE tenant_id = $1", [
            tenant
          ])
        end)

        GenServer.stop(admin)
      end
    end

    test "OP-12: the queue role cannot reach the application schema" do
      assert {:error, %Postgrex.Error{}} =
               QueueRepo.transaction(fn ->
                 case QueueRepo.query("SELECT count(*) FROM relay.notifications", []) do
                   {:ok, result} -> result
                   {:error, error} -> QueueRepo.rollback(error)
                 end
               end)
    end
  end
end
