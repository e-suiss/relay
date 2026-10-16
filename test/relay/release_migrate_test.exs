defmodule Relay.ReleaseMigrateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Relay.Release

  defp lock_timeout do
    %Postgrex.Error{
      postgres: %{
        severity: "ERROR",
        code: Postgrex.ErrorCode.code_to_name("55P03"),
        pg_code: "55P03",
        message: "canceling statement due to lock timeout"
      }
    }
  end

  defp flaky(failures) do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) <= failures, do: raise(lock_timeout()), else: :migrated
    end

    {fun, fn -> :counters.get(counter, 1) end}
  end

  defp sleeps do
    me = self()
    fn ms -> send(me, {:slept, ms}) end
  end

  describe "OP-57 migration retry on lock_timeout" do
    test "OP-57: a migration that hits lock_timeout is retried with backoff" do
      {fun, calls} = flaky(2)

      capture_log(fn ->
        assert Release.with_lock_retry(fun, sleep: sleeps()) == :migrated
      end)

      assert calls.() == 3
      assert_received {:slept, 1_000}
      assert_received {:slept, 2_000}
    end

    test "OP-57: after three attempts the lock_timeout error is raised" do
      {fun, calls} = flaky(3)

      capture_log(fn ->
        assert_raise Postgrex.Error, ~r/lock timeout/, fn ->
          Release.with_lock_retry(fun, sleep: sleeps())
        end
      end)

      assert calls.() == 3
    end

    test "OP-57: other database errors are not retried" do
      counter = :counters.new(1, [])

      fun = fn ->
        :counters.add(counter, 1, 1)

        raise %Postgrex.Error{
          postgres: %{
            severity: "ERROR",
            code: :undefined_table,
            pg_code: "42P01",
            message: "missing"
          }
        }
      end

      assert_raise Postgrex.Error, fn -> Release.with_lock_retry(fun, sleep: sleeps()) end
      assert :counters.get(counter, 1) == 1
      refute_received {:slept, _}
    end
  end
end
