defmodule Relay.ObservabilityTest do
  use ExUnit.Case, async: false

  alias Relay.Observability.Budget
  alias Relay.Observability.Handlers
  alias Relay.Observability.Slo
  alias Relay.Observability.TopTenants
  alias Relay.Observability.VmMonitor

  @rules "deploy/observability/alerts.yaml"
  @classes ~w(security action_required transactional operational system social marketing)a

  defp rules do
    {:ok, %{"groups" => groups}} = YamlElixir.read_from_file(@rules)
    for %{"rules" => rules} <- groups, rule <- rules, do: rule
  end

  defp alerts(prefix),
    do: for(%{"alert" => name} = rule <- rules(), String.starts_with?(name, prefix), do: rule)

  defp metrics, do: IO.iodata_to_binary(RelayWeb.Telemetry.prometheus())

  defp capture(event) do
    test = self()
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, event, fn _e, m, meta, _ -> send(test, {event, m, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "DS-42 SLO table" do
    test "DS-42: every message class has accept, handoff and availability targets" do
      assert Enum.sort(Slo.classes()) == Enum.sort(@classes)

      for class <- Slo.classes() do
        assert Slo.accept_ms(class) > 0
        assert Slo.handoff_ms(class) > Slo.accept_ms(class)
        assert Slo.availability(class) > 0.99 and Slo.availability(class) < 1
      end

      assert Slo.accept_ms(:security) == 300
      assert Slo.handoff_ms(:security) == 5_000
      assert Slo.availability(:security) == 0.9995
      assert Slo.handoff_ms(:marketing) == 1_800_000
      assert Slo.table()["window_days"] == 28
    end

    test "OP-36: the alert rules follow the SLO table" do
      objectives =
        for %{"record" => "relay:slo_objective", "labels" => labels, "expr" => expr} <- rules(),
            into: %{},
            do: {labels["class"], expr}

      for class <- Slo.classes() do
        name = Atom.to_string(class)
        assert objectives[name] == "vector(#{Slo.availability(class)})"
      end

      for sli <- ["Accept", "Handoff", "Availability"], burn <- Slo.burn_rates() do
        title = String.capitalize(burn["name"])
        assert [rule] = alerts("RelaySlo#{sli}#{title}Burn")
        assert rule["labels"]["severity"] == burn["severity"]
        assert rule["expr"] =~ "ratio_rate#{burn["long"]} >"
        assert rule["expr"] =~ "ratio_rate#{burn["short"]} >"
        assert rule["expr"] =~ "(#{burn["factor"]} * (1 -"
      end

      assert Enum.map(Slo.burn_rates(), & &1["factor"]) == [14.4, 6, 1]

      drop = Slo.proven_delivery_drop()
      assert [rule] = alerts("RelayProvenDeliveryDrop")
      assert rule["expr"] =~ "< #{1 - drop["drop"]} *"
      assert rule["expr"] =~ ">= #{drop["min_deliveries"]}"

      thresholds =
        for %{"record" => "relay:queue_age_threshold_seconds"} = rule <- rules(),
            into: %{},
            do: {rule["labels"]["lane"], rule["expr"]}

      for lane <- [:l0, :l1, :l2, :l3],
          do: assert(thresholds[Atom.to_string(lane)] == "vector(#{Slo.queue_age_seconds(lane)})")

      assert Slo.queue_age_seconds(:l0) == 5
      assert Slo.queue_age_seconds(:l3) == 1_800
    end

    test "OP-36: an accepted single event counts against its class's accept threshold" do
      capture([:relay, :slo, :accept])

      conn = %{
        method: "POST",
        path_info: ["v1", "events"],
        status: 202,
        private: %{relay_operation: "createEvent", relay_message_class: :security},
        assigns: %{}
      }

      fast = System.convert_time_unit(100, :millisecond, :native)
      slow = System.convert_time_unit(400, :millisecond, :native)
      Handlers.handle_event([:phoenix, :endpoint, :stop], %{duration: fast}, %{conn: conn}, nil)
      Handlers.handle_event([:phoenix, :endpoint, :stop], %{duration: slow}, %{conn: conn}, nil)

      failed = %{conn | status: 503}
      Handlers.handle_event([:phoenix, :endpoint, :stop], %{duration: fast}, %{conn: failed}, nil)

      assert_receive {_, %{count: 1}, %{class: :security, good: true}}
      assert_receive {_, %{count: 1}, %{class: :security, good: false}}
      refute_receive {_, _, _}

      assert metrics() =~ ~r/relay_slo_accept_total\{[^}]*class="security"/
    end

    test "TN-44: a kill switch that took effect counts against the effect target" do
      capture([:relay, :slo, :kill_switch])

      event = [:relay, :kill_switch, :effective]
      :telemetry.execute(event, %{duration_ms: 120_000}, %{platform: false})
      :telemetry.execute(event, %{duration_ms: 3_000}, %{platform: true})

      assert_receive {_, _, %{platform: false, good: false}}
      assert_receive {_, _, %{platform: true, good: true}}

      body = metrics()
      assert body =~ ~r/relay_slo_kill_switch_total\{[^}]*good="false"/
      assert body =~ "relay_kill_switch_effect_seconds"
      assert Slo.kill_switch_effect_seconds() == 90
    end
  end

  describe "T-68 performance budget" do
    test "T-68: a request belongs to the type of its operation, path or method" do
      request = &%{method: &1, path_info: String.split(&2, "/", trim: true), operation: &3}

      assert Budget.classify(request.("POST", "/v1/events", "createEvent")) == "accept"
      assert Budget.classify(request.("POST", "/v1/events/batch", "createEventBatch")) == "accept"
      assert Budget.classify(request.("GET", "/livez", nil)) == "health"
      assert Budget.classify(request.("POST", "/inbound/v1/sms/t/live/x", nil)) == "inbound"
      assert Budget.classify(request.("POST", "/v1/access/events", nil)) == "inbound"
      assert Budget.classify(request.("GET", "/v1/notifications", "listNotifications")) == "read"
      assert Budget.classify(request.("PATCH", "/v1/subscribers/x", "updateSub")) == "write"
      assert Budget.classify(request.("OPTIONS", "/v1/events", nil)) == nil
      assert Enum.sort(Budget.types()) == ~w(accept health inbound link read write)
    end

    test "T-68: a request over its latency or reduction budget is a breach of that resource" do
      assert Budget.breaches("health", 10, 1_000) == []
      assert Budget.breaches("health", 60, 1_000) == [:latency]
      assert Budget.breaches("health", 10, 200_000) == [:reductions]
      assert Budget.breaches("health", 60, 200_000) == [:latency, :reductions]
      assert Budget.objective() == 0.99
    end

    test "T-68: a finished request is counted against its budget" do
      capture([:relay, :request, :budget_breach])

      conn = %{
        method: "GET",
        path_info: ["livez"],
        status: 200,
        private: %{},
        assigns: %{}
      }

      slow = System.convert_time_unit(80, :millisecond, :native)
      Handlers.handle_event([:phoenix, :endpoint, :start], %{}, %{conn: conn}, nil)
      Handlers.handle_event([:phoenix, :endpoint, :stop], %{duration: slow}, %{conn: conn}, nil)

      assert_receive {_, %{count: 1}, %{type: "health", resource: :latency}}
      assert metrics() =~ ~r/relay_request_budget_total\{[^}]*type="health"/
    end
  end

  describe "OP-35 tenant label" do
    test "OP-35: the busiest tenants keep their label and the others are other" do
      tenants = for i <- 1..(TopTenants.size() + 5), do: {"tenant-#{i}", 1_000 + i}

      for {tenant, count} <- tenants, _ <- 1..count, do: TopTenants.count_job("q", tenant)
      :ok = TopTenants.close()

      {quiet, busy} = Enum.split(tenants, 5)
      for {tenant, _} <- busy, do: assert(TopTenants.label(tenant) == tenant)
      for {tenant, _} <- quiet, do: assert(TopTenants.label(tenant) == "other")
      assert TopTenants.label(nil) == "other"
      assert Relay.Observability.tenant_label("tenant-unknown") == "other"

      :ok = TopTenants.close()
      assert TopTenants.label("tenant-25") == "other"
    end
  end

  describe "TN-62 noisy neighbour" do
    test "TN-62: the largest share of a queue and of API requests is emitted each window" do
      capture([:relay, :neighbours, :share])

      for _ <- 1..90, do: TopTenants.count_job("tn62_queue", "tenant-a")
      for _ <- 1..10, do: TopTenants.count_job("tn62_queue", "tenant-b")
      for _ <- 1..60, do: TopTenants.count_client("client-a")
      for _ <- 1..40, do: TopTenants.count_client("client-b")
      :ok = TopTenants.close()

      assert_receive {_, %{share: 0.9}, %{signal: "queue_tenant", queue: "tn62_queue"}}
      assert_receive {_, %{share: share}, %{signal: "api_client", queue: "api"}}
      assert share >= 0.6

      :ok = TopTenants.close()
      assert_receive {_, %{share: +0.0}, %{signal: "queue_tenant", queue: "tn62_queue"}}
      assert metrics() =~ ~r/relay_noisy_neighbour_share\{[^}]*queue="tn62_queue"/
    end
  end

  describe "T-48 VM monitor" do
    test "T-48: a process is labelled by its registered name or initial call, never its pid" do
      assert VmMonitor.label(Process.whereis(TopTenants)) == "Relay.Observability.TopTenants"

      pid = spawn(fn -> Process.sleep(:infinity) end)
      label = VmMonitor.label(pid)
      refute label =~ "#PID"
      Process.exit(pid, :normal)

      port = Port.open({:spawn, "cat"}, [])
      assert VmMonitor.label(port) =~ "port:"
      Port.close(port)
    end

    test "T-48: the monitor runs at high priority with its mailbox off the heap" do
      pid = Process.whereis(VmMonitor)
      assert Process.info(pid, :priority) == {:priority, :high}
      assert Process.info(pid, :message_queue_data) == {:message_queue_data, :off_heap}
      assert {^pid, settings} = :erlang.system_monitor()
      assert {:long_schedule, 100} in settings
    end

    test "T-48: a system monitor report becomes telemetry with the process label" do
      capture([:relay, :vm, :monitor])
      pid = Process.whereis(VmMonitor)
      send(pid, {:monitor, Process.whereis(TopTenants), :long_gc, [timeout: 250]})
      name = "Relay.Observability.TopTenants"

      assert_receive {_, %{count: 1, value: 250}, %{kind: :long_gc, process: ^name}}
    end

    test "T-53: the periodic sample carries the VM counts, limits and dirty run queues" do
      capture([:relay, :vm, :sample])
      :ok = Relay.Observability.vm_sample()

      assert_receive {_, sample, %{}}
      assert sample.atom_count > 0 and sample.atom_limit > sample.atom_count
      assert is_integer(sample.dirty_cpu_run_queue) and is_integer(sample.dirty_io_run_queue)
      assert metrics() =~ "relay_vm_atom_count"
    end
  end
end
