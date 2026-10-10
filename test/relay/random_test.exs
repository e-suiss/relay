defmodule Relay.RandomTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Relay.Random.Strong

  setup :verify_on_exit!

  test "T-57: randomness comes from the injected source" do
    previous = Application.fetch_env!(:relay, :random)
    Application.put_env(:relay, :random, Relay.RandomMock)
    on_exit(fn -> Application.put_env(:relay, :random, previous) end)

    expect(Relay.RandomMock, :bytes, fn 4 -> <<1, 2, 3, 4>> end)
    assert Relay.Random.bytes(4) == <<1, 2, 3, 4>>
  end

  property "T-57: the strong source returns integers in 1..n" do
    check all n <- positive_integer() do
      value = Strong.uniform(n)
      assert value in 1..n
    end
  end

  test "T-57: the strong source returns the requested number of bytes" do
    assert byte_size(Strong.bytes(32)) == 32
  end
end
