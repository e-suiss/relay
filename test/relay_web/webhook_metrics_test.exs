defmodule RelayWeb.WebhookMetricsTest do
  use RelayWeb.ConnCase, async: false

  @events [
    [:relay, :webhooks, :attempt],
    [:relay, :webhooks, :batch],
    [:relay, :webhooks, :sweep],
    [:relay, :webhooks, :backlog],
    [:relay, :webhooks, :maintenance],
    [:relay, :webhooks, :operations_email]
  ]

  defp metrics, do: RelayWeb.Metrics.call(Plug.Test.conn(:get, "/metrics"), [])

  describe "T-63 webhook delivery metrics" do
    test "T-63, WH-10, WH-21, WH-28: every telemetry event of the delivery engine is a metric with tags from bounded sets" do
      metrics = RelayWeb.Telemetry.webhook_metrics()
      exported = RelayWeb.Telemetry.exported_metrics()

      events = metrics |> Enum.map(& &1.event_name) |> Enum.uniq()
      assert Enum.sort(events) == Enum.sort(@events)

      for metric <- metrics do
        assert metric in exported, inspect(metric.name)
        assert metric.tags -- [:result, :trigger, :first, :kind] == [], inspect(metric.name)
        assert [:relay, :webhooks | _rest] = metric.name
      end
    end

    test "T-63, OP-32: the engine's events are exported on /metrics" do
      attempt = %{result: "succeeded", trigger: "schedule", first: true}
      :telemetry.execute([:relay, :webhooks, :attempt], %{count: 1, duration_ms: 12}, attempt)

      batch = %{count: 1, events: 3, bytes: 900, duration_ms: 40}
      :telemetry.execute([:relay, :webhooks, :batch], batch, %{result: "delivered"})

      sweep = %{rescued: 1, requeued: 0, expired: 0, window_exceeded: 0, batches: 2}
      :telemetry.execute([:relay, :webhooks, :sweep], sweep, %{})
      :telemetry.execute([:relay, :webhooks, :backlog], %{age_ms: 1500}, %{})

      maintenance = %{keys_retired: 1, keys_destroyed: 1, responses: 4, payloads: 5}
      :telemetry.execute([:relay, :webhooks, :maintenance], maintenance, %{})

      mail = %{kind: "endpoint_disabled", result: :sent}
      :telemetry.execute([:relay, :webhooks, :operations_email], %{count: 1}, mail)

      body = response(metrics(), 200)

      for name <- ~w(relay_webhooks_attempt_total relay_webhooks_attempt_duration
                     relay_webhooks_batch_total relay_webhooks_batch_events_total
                     relay_webhooks_batch_bytes_total relay_webhooks_batch_duration
                     relay_webhooks_sweep_rescued_total relay_webhooks_sweep_batches_total
                     relay_webhooks_backlog_age_milliseconds
                     relay_webhooks_maintenance_responses_total
                     relay_webhooks_operations_email_total) do
        assert body =~ name, name
      end

      assert body =~ ~s(relay_webhooks_batch_events_total{result="delivered"})
      assert body =~ ~s(relay_webhooks_operations_email_total{kind="endpoint_disabled")
    end
  end
end
