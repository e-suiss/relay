defmodule Relay.Platform.BulkRepoTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Repo

  @moduletag :integration

  setup do
    oltp = Sandbox.start_owner!(Repo, shared: false)
    bulk = Sandbox.start_owner!(Relay.BulkRepo, shared: false)

    on_exit(fn ->
      Sandbox.stop_owner(bulk)
      Sandbox.stop_owner(oltp)
    end)

    :ok
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()", []).rows

  describe "T-32 (3) separate OLTP and bulk pools" do
    test "T-32 (3): the bulk pool has its own connections in the same database and login" do
      oltp = backend_pid()
      bulk = Relay.BulkRepo.run(&backend_pid/0)
      refute oltp == bulk

      [[oltp_user, oltp_db]] =
        Repo.query!("SELECT current_user::text, current_database()::text", []).rows

      assert Relay.BulkRepo.run(fn ->
               Repo.query!("SELECT current_user::text, current_database()::text", []).rows
             end) == [[oltp_user, oltp_db]]

      assert oltp_user == "relay_worker"
    end

    test "T-32 (3): bulk work never takes a connection from the OLTP pool" do
      test = self()
      handler = "bulk-repo-test-#{inspect(test)}"

      :telemetry.attach_many(
        handler,
        [[:relay, :repo, :query], [:relay, :bulk_repo, :query]],
        fn [:relay, pool, :query], _measurements, _meta, _config ->
          if self() == test, do: send(test, {:query, pool})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Relay.Platform.with_lane_pool(:l2, fn ->
        Repo.transaction(fn -> for _ <- 1..5, do: backend_pid() end)
      end)

      assert_received {:query, :bulk_repo}
      refute_received {:query, :repo}

      Relay.Platform.with_lane_pool(:l0, &backend_pid/0)
      assert_received {:query, :repo}
    end

    test "T-32 (3): run/1 restores the caller's pool afterwards, also after a raise" do
      refute Relay.BulkRepo.active?()
      assert Relay.BulkRepo.run(&Relay.BulkRepo.active?/0)
      assert_raise RuntimeError, fn -> Relay.BulkRepo.run(fn -> raise "boom" end) end
      refute Relay.BulkRepo.active?()
    end

    test "TN-14: the startup role check passes against the bulk pool" do
      assert Relay.Platform.Store.start_bulk_role_check() == :ignore
    end

    test "T-32 (3): worker nodes start the bulk pool and its role check; the pool reports its own telemetry" do
      ids = Enum.map(Relay.Platform.children(), &Supervisor.child_spec(&1, []).id)
      assert Relay.BulkRepo in ids
      assert :relay_bulk_role_check in ids
      assert Relay.BulkRepo.options()[:telemetry_prefix] == [:relay, :bulk_repo]
      assert Relay.BulkRepo.options()[:name] == Relay.BulkRepo
    end
  end
end
