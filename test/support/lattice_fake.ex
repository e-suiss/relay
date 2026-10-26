defmodule Relay.Policy.Lattice.Fake do
  @moduledoc "A policy lattice for rule tests: it answers each delivery with the decision function the calling process set with `decide/1`."

  @behaviour Relay.Policy.Lattice

  @doc "Sets the calling process's decision function: a function of the delivery returning a lattice decision."
  @spec decide((Relay.Policy.Lattice.delivery() -> Relay.Policy.Lattice.decision())) :: :ok
  def decide(fun) when is_function(fun, 1) do
    Process.put(__MODULE__, fun)
    :ok
  end

  @impl Relay.Policy.Lattice
  @doc "Answers with the calling process's decision function."
  @spec reevaluate(Relay.Policy.Lattice.delivery()) :: Relay.Policy.Lattice.decision()
  def reevaluate(delivery), do: Process.get(__MODULE__).(delivery)
end
