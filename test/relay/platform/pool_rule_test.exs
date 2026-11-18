defmodule Relay.Platform.PoolRuleTest do
  use ExUnit.Case, async: false

  alias Relay.Platform.PoolRule

  describe "OP-30 OP-88 connection pooling rule" do
    test "OP-30: demand is nodes times pool times two, the budget half of max_connections" do
      assert PoolRule.evaluate(4, 12, 200, false) == %{exceeded: false, demand: 96, budget: 100}
      assert PoolRule.evaluate(5, 12, 200, false) == %{exceeded: true, demand: 120, budget: 100}
    end

    test "OP-30: with a transaction-mode pooler in front the rule never warns" do
      assert %{exceeded: false, demand: 1_200} = PoolRule.evaluate(50, 12, 200, true)
    end

    test "OP-88: a breach at boot is a warning log and a metric, never a stop" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        ref,
        [:relay, :postgres, :pool_rule],
        fn _event, measurements, _meta, _ -> send(parent, {:pool_rule, measurements}) end,
        nil
      )

      previous = Application.get_env(:relay, PoolRule)
      Application.put_env(:relay, PoolRule, nodes: 1_000, pooler: "none")

      on_exit(fn ->
        :telemetry.detach(ref)

        if previous,
          do: Application.put_env(:relay, PoolRule, previous),
          else: Application.delete_env(:relay, PoolRule)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{exceeded: true} = PoolRule.check(100)
        end)

      assert log =~ "transaction-mode PgBouncer"
      assert_received {:pool_rule, %{exceeded: 1, budget: 50}}

      Application.put_env(:relay, PoolRule, nodes: 1_000, pooler: "pgbouncer")
      assert %{exceeded: false} = PoolRule.check(100)
      assert_received {:pool_rule, %{exceeded: 0}}
    end

    test "OP-30: the node pool counts the pools this node opens" do
      assert PoolRule.node_pool() > 0
    end
  end

  describe "OP-28 failover" do
    test "OP-28: every pool drops a connection that answers read_only_sql_transaction" do
      for repo <- [Relay.Repo, Relay.QueueRepo, Relay.Platform.MaintRepo] do
        codes = Keyword.fetch!(repo.config(), :disconnect_on_error_codes)
        assert :read_only_sql_transaction in codes, inspect(repo)
      end
    end
  end
end
