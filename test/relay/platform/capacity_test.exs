defmodule Relay.Platform.CapacityTest do
  use Relay.SqlCase, async: false

  alias Relay.Platform.Capacity
  alias RelayWeb.Api.Admission

  @job "INSERT INTO relay_queue.oban_jobs (state, queue, worker, args, scheduled_at, completed_at) VALUES ($1, $2, 'RelayTest.CapacityWorker', '{}', timezone('UTC', now()) + make_interval(secs => $3), timezone('UTC', now()) - make_interval(secs => $4))"
  @enqueue "SELECT relay_fn.drr_enqueue($1, 'l2', 'l2', 'RelayTest.CapacityWorker', '{}', 1::smallint, 1, $2, 'delivery', $3, 1000000)"

  setup do
    on_exit(fn -> Capacity.put(nil) end)
    :ok
  end

  defp capacity do
    Map.new(rows("SELECT lane, queued, completed FROM relay_ops.lane_capacity(60)"), fn
      [lane, queued, completed] -> {lane, {queued, completed}}
    end)
  end

  defp job(state, queue, scheduled_in_s \\ -1, completed_ago_s \\ 1) do
    completed_ago_s = if state == "completed", do: completed_ago_s, else: nil
    rows(@job, [state, queue, scheduled_in_s, completed_ago_s])
  end

  describe "T-35 (2) lane capacity" do
    test "T-35 (2): the backlog counts available jobs and due DRR waits; completions count within the window" do
      before = capacity()

      job("available", "l2")
      job("available", "l2")
      job("scheduled", "l2", 3_600)
      job("available", "l1")
      job("available", "l3_email")
      job("completed", "l3")
      job("completed", "l3", -1, 7_200)

      tenant = tenant!()
      "active" = ctx(tenant)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 86_400, :second)
      assert one(@enqueue, [id(), past, id()]) == "enqueued"
      assert one(@enqueue, [id(), future, id()]) == "enqueued"

      later = capacity()
      {q2, c2} = before["l2"]
      {q3, c3} = before["l3"]
      assert later["l2"] == {q2 + 3, c2}
      assert later["l3"] == {q3 + 1, c3 + 1}
      assert Map.keys(later) == ["l2", "l3"]

      assert {:ok, %{l3: {mu, 1_800_000, queued}}} = Capacity.sample()
      assert mu > 0
      assert queued == q3 + 1
      assert Capacity.current().l3 == {mu, 1_800_000, queued}
    end

    test "T-35 (2): μ is the configured rate, else the measured rate, else unknown" do
      rows = [
        %{"lane" => "l2", "queued" => 10, "completed" => 0},
        %{"lane" => "l3", "queued" => 5, "completed" => 120}
      ]

      assert Capacity.build(rows, %{}, 60) == %{l2: nil, l3: {2.0, 1_800_000, 5}}
      assert Capacity.build(rows, %{l2: 4}, 60) ==
               %{l2: {4, 60_000, 10}, l3: {2.0, 1_800_000, 5}}
      assert Capacity.build([], %{}, 60) == %{l2: nil, l3: nil}
    end
  end

  describe "T-35 (2) admission above L_max" do
    test "T-35 (2): a bulk lane whose backlog reaches μ · W_max is refused with Retry-After W_max" do
      Capacity.put(%{l2: {10, 60_000, 600}, l3: {1, 1_800_000, 1_800}})

      assert {:error, %Relay.Error{code: :service_unavailable} = l2} =
               Admission.check(:social, [:email])

      assert l2.details.retry_after == 60
      assert l2.message =~ "admission.lmax.l2"

      assert {:error, %Relay.Error{code: :service_unavailable} = l3} =
               Admission.check(:marketing, [:email])

      assert l3.details.retry_after == 1_800
      assert l3.message =~ "admission.lmax.l3"
      assert Admission.check(:transactional, [:email]) == :ok
      assert Admission.check(:security, [:email]) == :ok
    end

    test "T-35 (2): below L_max, an unmeasured lane and a node that never sampled admit" do
      Capacity.put(%{l2: {10, 60_000, 599}, l3: nil})
      assert Admission.check(:social, [:email]) == :ok
      assert Admission.check(:marketing, [:email]) == :ok

      Capacity.put(nil)
      assert Relay.Platform.lane_capacity() == nil
      assert Admission.check(:marketing, [:email]) == :ok
    end
  end
end
