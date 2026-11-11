defmodule Relay.Observability.RollupTest do
  use Relay.DataCase, async: false

  alias Relay.Observability.Rollup
  alias Relay.Observability.Store
  alias RelayTest.DeliveryFixture

  @kinds ~w(stage skipped anomaly outcome handoff availability gap queue_share)
  @lose_job """
  UPDATE relay_queue.oban_jobs SET args = args - 'delivery_id'
  WHERE args ->> 'delivery_id' = $1
  """

  defp rows(after_s \\ 60) do
    now = Relay.Clock.utc_now()
    from = DateTime.add(now, -3_600, :second)
    to = DateTime.add(now, after_s, :second)
    {:ok, rows} = Store.rollup(from, to, Rollup.handoff_ms())
    rows
  end

  defp sum(rows, kind, label),
    do: Enum.sum(for %{"kind" => ^kind, "label" => ^label, "total" => n} <- rows, do: n)

  defp row(kind, label, total, good) do
    %{
      "kind" => kind,
      "label" => label,
      "message_class" => "transactional",
      "channel" => "email",
      "provider" => "ses",
      "total" => total,
      "good" => good
    }
  end

  defp capture(events) do
    test = self()
    id = {__MODULE__, make_ref()}
    handler = fn event, m, meta, _ -> send(test, {event, m, meta}) end
    :ok = :telemetry.attach_many(id, events, handler, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "OP-33 funnel from the ledger" do
    test "OP-33: a delivery the provider accepted reaches each funnel stage" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      attempt = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, attempt, :succeeded, delivery_rank: :accepted)

      rows = rows()

      for stage <- ~w(accepted enqueued dispatched provider_accepted),
          do: assert(sum(rows, "stage", stage) >= 1, stage)

      availability = Enum.filter(rows, &(&1["kind"] == "availability"))
      assert Enum.sum(Enum.map(availability, & &1["good"])) >= 1
      assert sum(rows, "handoff", "") >= 1
      assert Enum.all?(rows, &(&1["kind"] in @kinds))
    end

    test "DS-36: a queued delivery whose job is gone is an accepted but not enqueued gap" do
      %{delivery_id: id} = DeliveryFixture.sendable!()
      assert sum(rows(600), "gap", "accepted_enqueued") == 0

      Repo.query!(@lose_job, [Relay.Id.to_string(id)])

      assert sum(rows(600), "gap", "accepted_enqueued") >= 1
    end
  end

  describe "OP-36 rollup task" do
    test "OP-36: a step emits the funnel and SLI telemetry and resets the gauges it lost" do
      stage = [:relay, :funnel, :stage]
      availability = [:relay, :slo, :availability]
      gap = [:relay, :funnel, :gap]
      capture([stage, availability, gap])

      rows = [row("stage", "enqueued", 3, 3), row("availability", "", 5, 4)]
      assert Rollup.emit(rows, [["gap", "accepted_enqueued", "sms", "twilio"]]) == []

      assert_receive {^stage, %{count: 3}, %{stage: "enqueued", channel: "email"}}
      assert_receive {^availability, %{count: 4}, %{class: "transactional", good: true}}
      assert_receive {^availability, %{count: 1}, %{good: false}}
      assert_receive {^gap, %{count: 0}, %{gap: "accepted_enqueued", channel: "sms"}}
    end

    test "TN-62: the largest tenant share of a queue's waiting jobs is emitted" do
      capture([[:relay, :neighbours, :share]])
      rows = [%{row("queue_share", "l3", 200, 150) | "channel" => "", "provider" => ""}]

      assert [["queue_share", "l3", "", ""]] = Rollup.emit(rows, [])
      assert_receive {_, %{share: 0.75}, %{signal: "queue_queued", queue: "l3"}}
    end

    test "OP-36: a step counts the window since the last one and saves where it stopped" do
      past = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), -120, :second))

      context = %{
        name: "observability_rollup",
        node: "n",
        fencing_token: 1,
        state: %{"to" => past}
      }

      assert {:ok, %{"to" => to, "gauges" => gauges}, 60_000} = Rollup.run(context)
      assert {:ok, _at, 0} = DateTime.from_iso8601(to)
      assert is_list(gauges)
      assert Rollup.handoff_ms()["security"] == 5_000
    end
  end
end
