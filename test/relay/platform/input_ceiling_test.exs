defmodule Relay.Platform.InputCeilingTest do
  use ExUnit.Case, async: false

  alias Relay.Platform.Capacity
  alias RelayWeb.Api.Admission

  defmodule Clock do
    @moduledoc false
    @behaviour Relay.Clock

    @impl Relay.Clock
    def utc_now, do: DateTime.utc_now()

    @impl Relay.Clock
    def monotonic_ms, do: Process.get({__MODULE__, :now}, 0)
  end

  setup do
    on_exit(fn -> Capacity.put(nil) end)
    :ok
  end

  defp at(ms), do: Process.put({Clock, :now}, ms)

  defp input(class) do
    %{
      message_class: class,
      channels: [:email],
      shed: %{l1: false, l2: false, l3: false},
      breaker_open: MapSet.new(),
      lane_capacity: nil
    }
  end

  describe "T-97 per-lane input ceiling" do
    test "T-97: each sample moves the ceilings of the lanes with a known μ" do
      capacity = %{l2: {10, 60_000, 0}, l3: nil}
      assert Capacity.step(%{}, capacity) == %{l2: 10.0, l3: nil}

      deep = %{l2: {10, 60_000, 500}, l3: {2, 1_800_000, 3_000}}
      assert Capacity.step(%{l2: 10.0, l3: 2.0}, deep) == %{l2: 5.0, l3: 1.0}
    end

    test "T-97: input above the ceiling is refused on the node's monotonic clock until it drains" do
      :ok = Capacity.put_ceilings(%{l2: 2.0, l3: nil})
      at(0)

      assert Capacity.admit_input(:l2, clock: Clock) == :ok
      assert Capacity.admit_input(:l2, clock: Clock) == :ok
      assert Capacity.admit_input(:l2, clock: Clock) == {:deny, 500}
      assert Capacity.admit_input(:l3, clock: Clock) == :ok

      at(500)
      assert Capacity.admit_input(:l2, clock: Clock) == :ok
    end

    test "T-97: over the ceiling the API answers 429 rate_limited with Retry-After; security is never refused" do
      :ok = Capacity.put_ceilings(%{l2: 1.0, l3: 0.1})

      assert Admission.decide(input(:social)) == :ok
      assert {:error, %Relay.Error{code: :rate_limited} = l2} = Admission.decide(input(:social))
      assert l2.details.retry_after >= 1
      assert l2.details.limit_name == "admission.aimd.l2"

      assert Admission.decide(input(:marketing)) == :ok
      assert {:error, %Relay.Error{code: :rate_limited} = l3} =
               Admission.decide(input(:marketing))
      assert l3.details.retry_after in 9..10
      assert l3.details.limit_name == "admission.aimd.l3"

      for _ <- 1..5, do: assert(Admission.decide(input(:security)) == :ok)
      for _ <- 1..5, do: assert(Admission.decide(input(:transactional)) == :ok)
    end

    test "T-97: a node that never sampled, or a lane without μ, sets no ceiling" do
      :ok = Capacity.put(nil)
      assert Capacity.ceilings() == %{}
      for _ <- 1..20, do: assert(Admission.decide(input(:social)) == :ok)

      :ok = Capacity.put_ceilings(Capacity.step(%{}, %{l2: nil, l3: nil}))
      for _ <- 1..20, do: assert(Admission.decide(input(:marketing)) == :ok)
    end
  end
end
