defmodule Relay.Policy.Lattice.Unavailable do
  @moduledoc """
  The stage 2 policy lattice: it is never ready (TN-70 (2)).
  """

  @behaviour Relay.Policy.Lattice

  # TN-70 (2)
  @impl Relay.Policy.Lattice
  @doc "Always `{:error, :not_ready}`."
  @spec reevaluate(Relay.Policy.Lattice.delivery()) :: {:error, :not_ready}
  def reevaluate(_delivery), do: {:error, :not_ready}
end
