defmodule Relay.Platform.Fairness.WaitPruneTest do
  use Relay.SqlCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.Queue.PrunerStore
  alias Relay.QueueRepo

  setup do
    owner = Sandbox.start_owner!(QueueRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  defp wait_row(admin, tenant, prunable_at) do
    wait = id()

    committed(admin, fn ->
      rows(
        """
        INSERT INTO relay_queue.drr_waits (tenant_id, environment, id, lane, queue, worker, args,
          priority, cost, scheduled_at, ref_kind, ref_id, state, state_changed_at, prunable_at, created_at)
        VALUES ($1, 'test', $2, 'l3', 'l3', 'RelayTest.DrrWorker', '{}', 1, 1, now(), 'delivery', $2,
          'dispatched', $3::timestamptz - interval '1 day', $3, now())
        """,
        [tenant, wait, prunable_at]
      )
    end)

    wait
  end

  defp exists?(wait) do
    {:ok, rows} =
      QueueRepo.transaction(fn ->
        QueueRepo.query!(
          "SELECT set_config('relay.tenant_id', '00000000-0000-0000-0000-000000000000', true), set_config('relay.environment', 'live', true)"
        )

        QueueRepo.query!("SELECT count(*) FROM relay_queue.drr_waits WHERE id = $1", [wait]).rows
      end)

    rows == [[1]]
  end

  describe "OP-74 OP-12 pruning the wait table" do
    test "OP-74: the queue role removes wait rows an hour after they became prunable and keeps the rest" do
      admin = connect(:admin)
      tenant = id()
      now = DateTime.utc_now()
      old = wait_row(admin, tenant, DateTime.add(now, -2 * 3_600, :second))
      fresh = wait_row(admin, tenant, DateTime.add(now, 86_400, :second))

      assert exists?(old)
      refute exists?(fresh)
      assert {:ok, counts} = PrunerStore.prune_ephemeral(10_000)
      assert {"drr_waits", removed} = List.keyfind(counts, "drr_waits", 0)
      assert removed >= 1
      refute exists?(old)

      assert on(admin, fn ->
               one("SELECT count(*) FROM relay_queue.drr_waits WHERE id = $1", [fresh])
             end) == 1
    end
  end
end
