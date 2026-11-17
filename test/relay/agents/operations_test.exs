defmodule Relay.Agents.OperationsTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.Operations

  @counts %{
    "silent_waitpoints" => 60,
    "stalled_waitpoints" => 4,
    "responses_hour" => 50,
    "median_response_ms" => 1_500,
    "opened_day" => 200,
    "responded_day" => 80,
    "opened_week" => 700,
    "responded_week" => 490,
    "resolved_week" => 400,
    "escalated_week" => 100,
    "evidence_channel_claim" => 7,
    "evidence_relay_session" => 5,
    "evidence_access_aas_ref" => 3,
    "held_notifications" => 2,
    "open_ceiling_events" => 1
  }

  defp attach(event) do
    ref = make_ref()
    pid = self()
    handler = "agent-operations-test-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, meta, _config -> send(pid, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  describe "AG-54 AG-71 agent operations gauges" do
    test "AG-71: the gauges carry the counts, the daily average and the rates in percent" do
      assert Operations.measurements(@counts) == %{
               silent_waitpoints: 60,
               stalled_waitpoints: 4,
               responses_hour: 50,
               median_response_ms: 1_500,
               opened_day: 200,
               opened_daily_average: 100,
               response_rate_day: 40,
               response_rate_week: 70,
               escalation_share: 25,
               held_notifications: 2,
               open_ceiling_events: 1
             }
    end

    test "AG-71: a rate with nothing to divide by is 0 and never above 100" do
      empty = Map.merge(@counts, %{"opened_day" => 0, "resolved_week" => 0})
      assert %{response_rate_day: 0, escalation_share: 0} = Operations.measurements(empty)

      late = Map.merge(@counts, %{"opened_day" => 10, "responded_day" => 30})
      assert %{response_rate_day: 100} = Operations.measurements(late)
    end

    test "AG-54: the overview counts every tenant by count only" do
      overview = Operations.overview(Relay.Clock.utc_now())

      assert Enum.sort(Map.keys(overview)) == Enum.sort(Map.keys(@counts))
      assert Enum.all?(Map.values(overview), &(is_integer(&1) and &1 >= 0))
    end

    test "AG-54: the report emits the gauges and the evidence levels" do
      overview = attach([:relay, :agents, :operations, :overview])
      evidence = attach([:relay, :agents, :operations, :evidence])

      assert :ok = Operations.report(@counts)

      assert_received {^overview, %{silent_waitpoints: 60, response_rate_week: 70}, %{}}
      assert_received {^evidence, %{count: 7}, %{level: "channel_claim"}}
      assert_received {^evidence, %{count: 5}, %{level: "relay_session"}}
      assert_received {^evidence, %{count: 3}, %{level: "access_aas_ref"}}
    end

    test "AG-54: the missed-timer sweep reports the gauges" do
      overview = attach([:relay, :agents, :operations, :overview])

      assert :ok = Relay.Agents.WaitpointSweep.perform(%Oban.Job{})
      assert_received {^overview, %{silent_waitpoints: silent}, %{}}
      assert is_integer(silent)
    end
  end
end
