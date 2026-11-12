defmodule Relay.Realtime.ConnectionsTest do
  use ExUnit.Case, async: true

  alias Relay.Realtime.Connections

  @moduletag :integration

  setup do
    %{scope: Relay.Scope.new!(:crypto.strong_rand_bytes(16), "live"), id: Relay.Id.generate()}
  end

  defp join!(ctx, device_id) do
    Process.sleep(2)
    {:ok, member, evicted} = Connections.join(ctx.scope, ctx.id, device_id)
    {member, evicted}
  end

  describe "IN-52 connections per subscriber" do
    test "IN-52: the eleventh connection pushes the oldest out and the others stay", ctx do
      [{oldest, 0} | rest] = for _n <- 1..10, do: join!(ctx, nil)
      assert Enum.all?(rest, &match?({_member, 0}, &1))

      {newest, 1} = join!(ctx, nil)

      assert :gone = Connections.touch(ctx.scope, ctx.id, oldest)
      assert :ok = Connections.touch(ctx.scope, ctx.id, newest)
      for {member, 0} <- rest, do: assert(:ok = Connections.touch(ctx.scope, ctx.id, member))
    end

    test "IN-52: subscribers do not share a set", ctx do
      for _n <- 1..10, do: join!(ctx, nil)
      other = %{ctx | id: Relay.Id.generate()}
      assert {_member, 0} = join!(other, nil)
    end
  end

  describe "IN-40 active connection of a device" do
    test "IN-40: a device is connected while its connection lives", ctx do
      {member, 0} = join!(ctx, "dev_a1")
      {_other, 0} = join!(ctx, nil)

      assert Relay.Realtime.connected?(ctx.scope, ctx.id, "dev_a1")
      refute Relay.Realtime.connected?(ctx.scope, ctx.id, "a1")
      refute Relay.Realtime.connected?(ctx.scope, ctx.id, "dev_b")
      refute Relay.Realtime.connected?(ctx.scope, Relay.Id.generate(), "dev_a1")

      assert :ok = Connections.leave(ctx.scope, ctx.id, member)
      refute Relay.Realtime.connected?(ctx.scope, ctx.id, "dev_a1")
    end

    test "IN-40: only well-formed device identifiers are accepted" do
      assert Connections.device?("dev_01HZ-x")
      refute Connections.device?("-")
      refute Connections.device?("a:b")
      refute Connections.device?(String.duplicate("a", 65))
      refute Connections.device?(nil)
    end
  end
end
