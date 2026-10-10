defmodule Relay.ClockTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env!(:relay, :clock)
    Application.put_env(:relay, :clock, Relay.ClockMock)
    on_exit(fn -> Application.put_env(:relay, :clock, previous) end)
  end

  test "T-57: time comes from the injected clock" do
    fixed = ~U[2026-10-10 08:00:00.000000Z]
    expect(Relay.ClockMock, :utc_now, fn -> fixed end)
    expect(Relay.ClockMock, :monotonic_ms, fn -> 42 end)

    assert Relay.Clock.utc_now() == fixed
    assert Relay.Clock.monotonic_ms() == 42
  end

  test "T-57: the system clock returns UTC with microsecond precision" do
    now = Relay.Clock.System.utc_now()
    assert now.time_zone == "Etc/UTC"
    assert {_, 6} = now.microsecond
  end
end
