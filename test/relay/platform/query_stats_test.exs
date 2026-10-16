defmodule Relay.Platform.QueryStatsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.Store

  setup do
    me = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:relay, :postgres, :query_stats],
      fn _event, measurements, meta, _ -> send(me, {:query_stats, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "OP-11 query statistics" do
    test "OP-11: a server that preloads pg_stat_statements passes silently" do
      assert Store.query_stats_check(fn _sql, [] -> {:ok, [[true]]} end) == :ok
      refute_received {:query_stats, _, _}
    end

    test "OP-11: a missing pg_stat_statements is an alarm, not a stop" do
      log =
        capture_log(fn ->
          assert Store.query_stats_check(fn _sql, [] -> {:ok, [[false]]} end) ==
                   {:error, :query_stats_missing}
        end)

      assert log =~ "pg_stat_statements"
      assert_received {:query_stats, %{count: 1}, %{status: :missing}}
    end

    test "OP-11: a failed check is logged and the node keeps starting" do
      capture_log(fn ->
        assert Store.query_stats_check(fn _sql, [] -> {:error, "connection refused"} end) ==
                 {:error, "connection refused"}
      end)

      refute_received {:query_stats, _, _}
    end

    test "OP-11: the startup check never stops the node" do
      assert %{id: :relay_query_stats_check, restart: :temporary} =
               Enum.find(Relay.Platform.children(), &match?(%{id: :relay_query_stats_check}, &1))
    end

    test "OP-11: the local PostgreSQL preloads pg_stat_statements" do
      compose = File.read!("deploy/compose.yaml")
      assert compose =~ "shared_preload_libraries=pg_stat_statements"
    end
  end

  describe "OP-11 real server" do
    @describetag :integration

    setup do
      pid = Sandbox.start_owner!(Relay.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    test "OP-11: the test database collects query statistics" do
      assert Store.query_stats_check() == :ok
      assert Store.start_query_stats_check() == :ignore
    end
  end
end
