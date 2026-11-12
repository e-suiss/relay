defmodule Relay.Policy.NextBreakTest do
  use ExUnit.Case, async: true

  alias Relay.Policy.Engine
  alias Relay.Policy.Fixture

  @night [%{days: [1, 2, 3, 4, 5, 6, 7], from: ~T[22:00:00], to: ~T[07:00:00]}]
  @afternoon [%{days: [1, 2, 3, 4, 5, 6, 7], from: ~T[14:00:00], to: ~T[16:00:00]}]
  @detail [:local_time, :local_until, :max_defer_until, :timezone, :timezone_source]

  defp evaluate(changes), do: changes |> Fixture.snapshot() |> Engine.evaluate()

  defp waiting(until, released \\ false), do: %{until: until, released: released}

  defp push(class, next_break, quiet \\ []) do
    [
      channel: :push,
      target: [platform: :android],
      notification: [message_class: class, next_break: next_break],
      category: [channel_defaults: %{push: :on}],
      profile: [quiet_hours: quiet]
    ]
  end

  defp assert_at(%DateTime{} = actual, %DateTime{} = expected),
    do: assert(DateTime.compare(actual, expected) == :eq, "#{actual} is not #{expected}")

  describe "WF-56 next break" do
    test "WF-56: a waiting push goes at the end of the next quiet hours or at max_defer" do
      late = waiting(~U[2026-11-03 10:00:00Z])

      assert {:defer, :next_break, "next_break.deferred", until, detail} =
               evaluate(push(:transactional, late, @night))

      assert_at(until, ~U[2026-11-03 04:00:00Z])
      assert_at(detail.max_defer_until, ~U[2026-11-03 10:00:00Z])

      soon = waiting(~U[2026-11-02 15:00:00Z])

      assert {:defer, :next_break, _, until, _} = evaluate(push(:operational, soon, @night))
      assert_at(until, ~U[2026-11-02 15:00:00Z])

      assert {:defer, :next_break, _, until, _} = evaluate(push(:social, late))
      assert_at(until, ~U[2026-11-03 10:00:00Z])
    end

    test "WF-56, IN-48: the deferral detail never carries a device status" do
      assert {:defer, _, _, _, detail} =
               evaluate(push(:transactional, waiting(~U[2026-11-03 10:00:00Z]), @night))

      assert Enum.sort(Map.keys(detail)) == @detail
    end

    test "WF-56: a released or due break passes, and quiet hours stay a hard limit" do
      released = waiting(~U[2026-11-03 10:00:00Z], true)
      assert {:send, _info} = evaluate(push(:transactional, released))

      due = waiting(~U[2026-11-02 12:00:00Z])
      assert {:send, _info} = evaluate(push(:transactional, due))

      assert {:defer, :quiet_hours, "quiet_hours.deferred", _, _} =
               evaluate(push(:transactional, released, @afternoon))

      assert {:defer, :quiet_hours, "quiet_hours.deferred", _, _} =
               evaluate(push(:transactional, due, @afternoon))
    end

    test "WF-56, PC-45: in-app, webhook and e-mail outside quiet hours never wait" do
      late = waiting(~U[2026-11-03 10:00:00Z])

      for channel <- [:in_app, :webhook, :email] do
        changes =
          push(:transactional, late, @night)
          |> Keyword.put(:channel, channel)
          |> Keyword.put(:category, channel_defaults: %{channel => :on})

        assert {:send, _info} = evaluate(changes), inspect(channel)
      end
    end

    test "WF-56, E-77: security and system never wait for a break" do
      late = waiting(~U[2026-11-03 10:00:00Z])

      for class <- [:security, :system] do
        assert {:send, _info} = evaluate(push(class, late, @afternoon)), inspect(class)
      end
    end

    test "WF-57, PC-46: an explicit next_break action_required waits, never in quiet hours" do
      late = waiting(~U[2026-11-03 10:00:00Z])

      assert {:defer, :next_break, "next_break.deferred", _, _} =
               evaluate(push(:action_required, late))

      released = waiting(~U[2026-11-03 10:00:00Z], true)

      assert {:defer, :quiet_hours, "quiet_hours.deferred", until, _} =
               evaluate(push(:action_required, released, @afternoon))

      assert_at(until, ~U[2026-11-02 13:00:00Z])
      assert {:send, _info} = evaluate(push(:action_required, nil, @afternoon))
    end
  end
end
