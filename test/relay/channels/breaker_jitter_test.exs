defmodule Relay.Channels.BreakerJitterTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Breaker.Core

  @row %{"open_ms" => 20_000, "open_jitter_bp" => 3000}

  test "T-25 (6), T-30: the open time follows the J5 vector" do
    assert Core.open_until(0, 1, @row, "relay@node-a", "provider:apns") == 24_973
    assert Core.open_until(1000, 1, @row, "relay@node-a", "provider:apns") == 25_973
  end

  test "T-25 (6): two nodes and two openings get different open times within 30 %" do
    a = Core.open_until(0, 1, @row, "relay@node-a", "provider:apns")
    b = Core.open_until(0, 1, @row, "relay@node-b", "provider:apns")
    second = Core.open_until(0, 2, @row, "relay@node-a", "provider:apns")

    assert a != b
    assert a != second

    for t <- [a, b, second], do: assert(t >= 20_000 and t <= 26_000)
  end
end
