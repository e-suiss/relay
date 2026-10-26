defmodule Relay.Platform.Fairness.QueueingTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.LoadShed
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @moduletag :integration

  defmodule LaneWorker do
    use Oban.Worker, queue: :l2, max_attempts: 3

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  @released %{l0: false, l1: false, l2: false, l3: false}

  setup do
    bulk = Sandbox.start_owner!(Relay.BulkRepo, shared: false)
    queue = Sandbox.start_owner!(Relay.QueueRepo, shared: false)
    previous = Repo.put_dynamic_repo(Relay.BulkRepo)
    LoadShed.put_engaged(@released)

    on_exit(fn ->
      LoadShed.put_engaged(@released)
      Sandbox.stop_owner(queue)
      Sandbox.stop_owner(bulk)
    end)

    tenant = TenantFixture.tenant!()
    {:ok, scope: tenant.test, previous: previous}
  end

  defp job(lane, opts \\ []) do
    %{
      id: Relay.Id.generate(),
      lane: lane,
      worker: LaneWorker,
      args: %{"delivery_id" => Relay.Id.to_string(Relay.Id.generate())},
      ref_kind: "delivery",
      ref_id: Keyword.get_lazy(opts, :ref, &Relay.Id.generate/0),
      priority: Keyword.get(opts, :priority, 1),
      cost: Keyword.get(opts, :cost, 1),
      scheduled_at: DateTime.add(Relay.Clock.utc_now(), -5, :second)
    }
  end

  defp enqueue(scope, attrs, opts \\ []) do
    {:ok, result} =
      Repo.in_scope(scope, fn _status -> Relay.Platform.enqueue_job(attrs, opts) end)

    result
  end

  defp lease! do
    %{rows: [[_result, token]]} =
      Repo.query!(
        "SELECT * FROM relay_ops.singleton_acquire('drr_dispatcher', 'queueing-test', interval '30 seconds')",
        []
      )

    token
  end

  defp jobs(queue) do
    Repo.query!(
      "SELECT state::text, worker, args, priority, max_attempts FROM relay_queue.oban_jobs WHERE queue = $1 ORDER BY id",
      [queue]
    ).rows
  end

  defp step(token),
    do: Relay.Platform.fair_dispatch_step(token, nil, System.os_time(:millisecond))

  describe "T-21 (4) T-21 (2) entering a lane" do
    test "T-21 (4): an l0 job goes straight to its queue inside the writing transaction", %{
      scope: scope
    } do
      attrs = job(:l0, priority: 0)
      assert enqueue(scope, attrs) == {:ok, :queued}

      assert [["available", "Relay.Platform.Fairness.QueueingTest.LaneWorker", args, 0, 3]] =
               jobs("l0")

      assert args == attrs.args
    end

    test "T-21 (2): an l2 job waits; the dispatcher step queues it in the same transaction as the round",
         %{
           scope: scope
         } do
      attrs = job(:l2, priority: 5)
      assert enqueue(scope, attrs) == {:ok, :waiting}
      assert enqueue(scope, attrs) == {:ok, :exists}
      assert jobs("l2") == []

      assert {:ok, %{dispatched: %{l2: 1, l3: 0}}} = step(lease!())

      assert [["available", "Relay.Platform.Fairness.QueueingTest.LaneWorker", args, 5, 3]] =
               jobs("l2")

      assert args == attrs.args
      assert {:ok, %{dispatched: %{l2: 0}}} = step(lease!())
    end

    test "T-21 (3): cancelling the record keeps its waiting job out of the queue", %{scope: scope} do
      ref = Relay.Id.generate()
      assert enqueue(scope, job(:l3, ref: ref)) == {:ok, :waiting}

      assert {:ok, {:ok, 1}} =
               Repo.in_scope(scope, fn _ ->
                 Relay.Platform.cancel_waiting_jobs("delivery", ref, "notification.cancelled")
               end)

      assert {:ok, %{dispatched: %{l3: 0}}} = step(lease!())
      assert jobs("l3") == []
    end

    test "T-34 (2): while l3 sheds its round does not run and its jobs keep waiting", %{
      scope: scope
    } do
      assert enqueue(scope, job(:l3)) == {:ok, :waiting}
      LoadShed.put_engaged(%{@released | l3: true})
      assert {:ok, %{dispatched: %{l3: 0}}} = step(lease!())
      assert jobs("l3") == []

      LoadShed.put_engaged(@released)
      assert {:ok, %{dispatched: %{l3: 1}}} = step(lease!())
    end

    test "TN-54: the tenant's waiting jobs stop at its cap", %{scope: scope} do
      assert enqueue(scope, job(:l2), queued_cap: 1) == {:ok, :waiting}

      assert {:error, %Relay.Error{code: :queued_cap_exceeded}} =
               enqueue(scope, job(:l2), queued_cap: 1)
    end

    test "T-21 (2): a job may not cost more than the quantum", %{scope: scope} do
      assert_raise ArgumentError, fn -> enqueue(scope, job(:l2, cost: 5_001)) end
    end

    test "T-12: a dispatcher step under a stale fencing token is refused", %{scope: scope} do
      assert enqueue(scope, job(:l2)) == {:ok, :waiting}
      assert step(lease!() + 1) == :not_leader
    end

    test "TN-13: a lane job is written only inside a scoped transaction" do
      assert_raise Relay.ScopeError, fn -> Relay.Platform.enqueue_job(job(:l1)) end
      assert_raise Relay.ScopeError, fn -> Relay.Platform.enqueue_job(job(:l2)) end
    end
  end
end
