defmodule Relay.ApplicationTest do
  use ExUnit.Case, async: true

  test "T-3: one release serves every role" do
    assert Relay.Role.all() == [:api, :worker, :socket]
    assert Relay.Role.configured() == [:api, :worker, :socket]
    assert Relay.Role.serves_http?()
  end

  test "T-44: the VM release flags carry no memory or topology flags" do
    vm_args = File.read!("rel/vm.args.eex")
    refute vm_args =~ ~r/^\+(S|SP|sbt|MBas|MHas|MMmcs|hmax)\b/m
  end

  test "T-83: process heap size is limited in observation mode: reported, never killed" do
    assert %{size: 32_000_000, kill: false, error_logger: true} =
             :erlang.system_info(:max_heap_size)
  end
end
