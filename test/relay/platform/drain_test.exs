defmodule Relay.Platform.DrainTest do
  use ExUnit.Case, async: false

  alias Relay.Platform.Drain
  alias Relay.Realtime.Drain, as: RealtimeDrain
  alias RelayWeb.Realtime.Drainer

  defp listen(names) do
    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      ref,
      names,
      fn event, measurements, meta, _ -> send(pid, {event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  describe "OP-87 shutdown order" do
    test "OP-87: stopping the coordinator withdraws readiness first, waits, then stops the queues and waits for their jobs" do
      listen([[:relay, :drain, :phase]])
      name = :drain_order_test
      on_exit(fn -> Drain.restore(name) end)

      pid =
        start_supervised!(
          {Drain, name: name, lb_wait_ms: 120, jobs_ms: 50, poll_ms: 10, oban: nil, queues: []}
        )

      refute Drain.draining?(name)
      started = Relay.Clock.monotonic_ms()
      :ok = stop_supervised(name)
      refute Process.alive?(pid)
      assert Drain.draining?(name)

      assert_received {[:relay, :drain, :phase], %{monotonic_ms: readiness}, %{phase: :readiness}}
      assert_received {[:relay, :drain, :phase], %{monotonic_ms: queues}, %{phase: :queues}}

      assert_received {[:relay, :drain, :phase], %{monotonic_ms: jobs, running: 0},
                       %{phase: :jobs}}

      assert readiness >= started
      assert queues - readiness >= 120
      assert jobs >= queues
    end

    test "OP-87: the supervisor waits for the load balancer wait and the job drain, with a margin" do
      spec = Drain.child_spec([])
      assert spec.shutdown == 10_000 + 30_000 + 5_000
      assert Drainer.child_spec([]).shutdown == 15_000 + 5_000
      assert spec.shutdown + Drainer.child_spec([]).shutdown <= 75_000
    end

    test "OP-87: a draining node is not ready whatever its dependencies" do
      on_exit(fn -> Drain.restore() end)
      :ok = Drain.withdraw()
      assert Relay.Platform.draining?()
      assert {:error, %Relay.Error{code: :draining}} = Relay.Platform.readiness()
    end
  end

  describe "IN-34 realtime drain" do
    test "IN-34: connections are spread over the window in batches, never empty, never more than the window holds" do
      assert RealtimeDrain.batches([], 15_000, 1_000) == []
      assert RealtimeDrain.batches([:a, :b], 15_000, 1_000) == [[:a], [:b]]

      batches = RealtimeDrain.batches(Enum.to_list(1..100), 15_000, 1_000)
      assert length(batches) == 15
      assert Enum.concat(batches) == Enum.to_list(1..100)
      assert batches |> Enum.map(&length/1) |> Enum.uniq() |> Enum.sort() == [6, 7]
      assert Enum.all?(batches, &(&1 != []))

      assert [[1, 2, 3]] = RealtimeDrain.batches([1, 2, 3], 500, 1_000)
    end

    test "IN-34: each drained connection gets its own reconnect hint within the contract's range" do
      min = Relay.Limits.fetch!(["realtime", "retry_after_seconds", "min"])
      max = Relay.Limits.fetch!(["realtime", "retry_after_seconds", "max"])

      assert Drainer.drain([self(), self(), self()], 30, 10) == 3

      for _ <- 1..3 do
        assert_received {:relay_realtime_drain, hint}
        assert hint >= min and hint <= max
      end
    end

    test "IN-34: a tracked connection is on the node's list until it exits" do
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = RealtimeDrain.track()
          send(parent, :tracked)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :tracked
      assert pid in RealtimeDrain.connections()
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      Process.sleep(20)
      refute pid in RealtimeDrain.connections()
    end
  end
end
