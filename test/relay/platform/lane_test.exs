defmodule Relay.Platform.LaneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Platform.Lane

  @classes [
    :security,
    :transactional,
    :action_required,
    :operational,
    :system,
    :social,
    :marketing
  ]

  describe "T-31 INV-16 INV-24 lane from the message class only" do
    test "T-31: the class table puts every class on its lane" do
      assert Map.new(@classes, &{&1, Lane.of(&1)}) == %{
               security: :l0,
               transactional: :l1,
               action_required: :l1,
               operational: :l2,
               system: :l2,
               social: :l2,
               marketing: :l3
             }
    end

    test "T-31: social is a deferrable lane, never L1" do
      assert Lane.of(:social) == :l2
      assert Lane.fair?(Lane.of(:social))
    end

    test "INV-24: only security runs on l0" do
      assert for(class <- @classes, Lane.of(class) == :l0, do: class) == [:security]
    end

    test "INV-16: the lane function takes the class and nothing else" do
      exports = Lane.__info__(:functions)
      assert {:of, 1} in exports
      refute Enum.any?(exports, fn {name, arity} -> name == :of and arity != 1 end)

      {:ok, specs} = Code.Typespec.fetch_specs(Lane)
      [{{:of, 1}, [spec]}] = for {{:of, _}, _} = s <- specs, do: s

      assert Macro.to_string(Code.Typespec.spec_to_quoted(:of, spec)) ==
               "of(message_class()) :: t()"
    end

    test "INV-16: a request field cannot move a transactional message to another lane" do
      request = %{class: :transactional, priority: :high, channel: :sms, lane: :l0}
      assert Relay.Platform.lane(request.class) == :l1
      assert Lane.of(request.class) == :l1
    end

    property "INV-16: the lane depends on the class alone, whatever else the request carries" do
      check all(
              class <- member_of(@classes),
              priority <- member_of([:high, :normal, :low]),
              channel <- member_of(Lane.channels())
            ) do
        request = %{class: class, priority: priority, channel: channel}
        assert Lane.of(request.class) == Lane.of(class)
      end
    end

    test "T-21 (4): the bulk lanes are fair, the critical lanes are not" do
      assert Enum.filter(Lane.all(), &Lane.fair?/1) == [:l2, :l3]
    end

    test "T-32 (3): the critical lanes write through the OLTP pool, the bulk lanes through the bulk pool" do
      assert Map.new(Lane.all(), &{&1, Lane.pool(&1)}) == %{
               l0: :oltp,
               l1: :oltp,
               l2: :bulk,
               l3: :bulk
             }
    end
  end
end
