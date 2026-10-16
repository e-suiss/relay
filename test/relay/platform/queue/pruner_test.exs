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
