defmodule Relay.Platform.Valkey.GuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Platform.Valkey.Guard
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  defp start_guard(name) do
    allow(ValkeyMock, self(), fn -> GenServer.whereis(name) end)
    expect(ValkeyMock, :subscribe, fn "relay:s:guard" -> :ok end)
    start_supervised!({Guard, name: name, adapter: ValkeyMock})
  end

  defp info(policy), do: {:ok, "# Memory\r\nmaxmemory_policy:#{policy}\r\n"}

  test "T-9: the eviction policy is checked when the connection comes up" do
    name = :relay_guard_test
    pid = start_guard(name)
    assert Guard.status(name) == :unknown

    expect(ValkeyMock, :command, fn ["INFO", "memory"] -> info("noeviction") end)
    send(pid, {:valkey, :up, "relay:s:guard"})

    assert Guard.status(name) == :ok
  end

  test "T-9: an evicting Valkey is reported as an error, and the node keeps running" do
    name = :relay_guard_test
    pid = start_guard(name)
    expect(ValkeyMock, :command, fn ["INFO", "memory"] -> info("allkeys-lru") end)

    log =
      capture_log(fn ->
        send(pid, {:valkey, :up, "relay:s:guard"})
        assert Guard.status(name) == {:mismatch, "allkeys-lru"}
      end)

    assert log =~ "noeviction"
    assert Process.alive?(pid)
  end

  test "T-9: an unreachable Valkey keeps the status unknown and retries later" do
    name = :relay_guard_test
    pid = start_guard(name)

    expect(ValkeyMock, :command, fn _ -> {:error, %Redix.ConnectionError{reason: :closed}} end)
    send(pid, {:valkey, :up, "relay:s:guard"})
    assert Guard.status(name) == :unknown

    expect(ValkeyMock, :command, fn _ -> info("noeviction") end)
    send(pid, :check)
    assert Guard.status(name) == :ok
  end
end
