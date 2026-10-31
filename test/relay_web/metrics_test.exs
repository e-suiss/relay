defmodule RelayWeb.MetricsTest do
  use RelayWeb.ConnCase, async: false

  @rules "deploy/observability/alerts.yaml"

  @events [
    {[:relay, :partition, :horizon_alarm], %{count: 1}, %{table: "delivery_events"},
     ~s(relay_partition_horizon_alarm_timestamp_seconds{table="delivery_events"})},
    {[:relay, :leadership, :state], %{leaderless: 1}, %{task: "audit_checkpoint"},
     ~s(relay_leadership_leaderless{task="audit_checkpoint"} 1)},
    {[:relay, :audit, :overdue], %{delay_ms: 5_000}, %{},
     "relay_audit_checkpoint_overdue_timestamp_seconds "},
    {[:relay, :audit, :unpublished], %{count: 1}, %{origin: "relay.test/relay/audit/2026"},
     "relay_audit_checkpoint_unpublished_timestamp_seconds "},
    {[:relay, :audit, :mismatch], %{count: 1}, %{kind: :published_mismatch, origin: "o"},
     ~s(relay_audit_mismatch_timestamp_seconds{kind="published_mismatch"})},
    {[:relay, :queue, :mode], %{polling: 1}, %{component: :notifier},
     ~s(relay_queue_polling{component="notifier"} 1)},
    {[:relay, :integrity, :violation], %{violations: 2}, %{check: "fk_missing", table: "t"},
     ~s(relay_integrity_violation_timestamp_seconds{check="fk_missing",table="t"})},
    {[:relay, :integrity, :run], %{count: 1}, %{}, "relay_integrity_last_run_timestamp_seconds "},
    {[:relay, :projection, :difference], %{count: 1}, %{environment: :live},
     "relay_projection_difference_timestamp_seconds "},
    {[:relay, :postgres, :query_stats], %{count: 1}, %{status: :missing},
     "relay_postgres_query_stats_missing 1"},
    {[:relay, :valkey, :guard], %{mismatch: 1}, %{}, "relay_valkey_eviction_policy_mismatch 1"},
    {[:relay, :access, :link], %{down: 1}, %{state: :stale, result: :unchanged},
     "relay_access_link_down 1"}
  ]

  defp with_metrics(config, fun) do
    previous = Application.get_env(:relay, RelayWeb.Metrics)
    Application.put_env(:relay, RelayWeb.Metrics, config)

    try do
      fun.()
    after
      Application.put_env(:relay, RelayWeb.Metrics, previous)
    end
  end

  defp children, do: RelayWeb.Metrics.children()

  defp metrics, do: RelayWeb.Metrics.call(Plug.Test.conn(:get, "/metrics"), [])

  defp prometheus_name(metric), do: Enum.map_join(metric.name, "_", &Atom.to_string/1)

  defp rules do
    {:ok, %{"groups" => groups}} = YamlElixir.read_from_file(@rules)
    for %{"rules" => rules} <- groups, rule <- rules, do: rule
  end

  describe "OP-69 alarms" do
    test "OP-69: every stage 1 alarm metric has an alert rule and every rule reads an alarm metric" do
      names = Enum.map(RelayWeb.Telemetry.alarm_metrics(), &prometheus_name/1)
      exprs = Enum.map(rules(), & &1["expr"])

      for name <- names, do: assert(Enum.any?(exprs, &(&1 =~ ~r/\b#{name}\b/)), name)

      for expr <- exprs,
          do: assert(Enum.any?(names, &(expr =~ ~r/\b#{&1}\b/)), expr)

      assert length(names) == length(Enum.uniq(names))

      for rule <- rules() do
        assert rule["labels"]["severity"] in ["page", "warning"], rule["alert"]
        assert rule["labels"]["decision"] =~ ~r/^[A-Z]+-\d+$/, rule["alert"]
      end
    end

    test "OP-69: every alarm event is exported on /metrics in the Prometheus format" do
      for {event, measurements, meta, _line} <- @events,
          do: :telemetry.execute(event, measurements, meta)

      conn = metrics()
      body = response(conn, 200)
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/plain"

      for {_event, _measurements, _meta, line} <- @events, do: assert(body =~ line, line)

      assert body =~ "# TYPE relay_leadership_leaderless gauge"
    end

    test "OP-69: a state alarm clears when the state returns to normal" do
      :telemetry.execute([:relay, :queue, :mode], %{polling: 1}, %{component: :stager})
      :telemetry.execute([:relay, :queue, :mode], %{polling: 0}, %{component: :stager})

      assert response(metrics(), 200) =~ ~s(relay_queue_polling{component="stager"} 0)
    end

    test "OP-69: the local Prometheus loads the alert rules and scrapes the node" do
      config = File.read!("deploy/observability/prometheus.yaml")
      compose = File.read!("deploy/compose.yaml")

      assert config =~ "/etc/prometheus/alerts.yaml"
      assert config =~ "metrics_path: /metrics"
      assert config =~ "host.docker.internal:9568"
      assert compose =~ "./observability/alerts.yaml:/etc/prometheus/alerts.yaml:ro"
    end

    test "OP-71: /metrics is served on the internal metrics port and not by the API endpoint", %{
      conn: conn
    } do
      assert response(get(conn, "/metrics"), 404)
      assert response(RelayWeb.Metrics.call(Plug.Test.conn(:get, "/livez"), []), 404)

      runtime = File.read!("config/runtime.exs")
      assert runtime =~ ~s[port: Relay.Config.Env.integer!("METRICS_PORT")]

      values = File.read!("deploy/helm/relay/values.yaml")
      env = File.read!("deploy/helm/relay/templates/_env.tpl")
      deployment = File.read!("deploy/helm/relay/templates/deployment.yaml")
      service = File.read!("deploy/helm/relay/templates/service.yaml")

      assert values =~ ~r/^metrics:\n  port: \d+$/m
      assert env =~ "METRICS_PORT"
      assert deployment =~ "containerPort: {{ $.Values.metrics.port }}"
      refute service =~ "metrics"

      config = [server: true, ip: {127, 0, 0, 1}, port: 9999]
      assert [%{start: {Bandit, :start_link, [opts]}}] = with_metrics(config, &children/0)
      assert opts[:plug] == RelayWeb.Metrics
      assert opts[:port] == 9999
      assert with_metrics([server: false], &children/0) == []
    end

    test "T-63: alarm metric tags come from bounded sets" do
      for metric <- RelayWeb.Telemetry.alarm_metrics(),
          do: assert(metric.tags -- [:table, :task, :kind, :component, :check] == [], metric.name)
    end
  end
end
