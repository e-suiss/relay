defmodule Relay.Policy.Lattice do
  @moduledoc """
  The policy lattice port: preference, İYS, quiet hours, frequency and quota decide again whether a paused delivery may go (TN-40). Resuming a kill switch passes every delivery through it. Until the lattice exists (stages 4 and 11) the only implementation is `Relay.Policy.Lattice.Unavailable`, which is never ready, so resume is refused and paused deliveries wait (TN-70 (2)). The implementation is configured as `config :relay, Relay.Policy.Lattice, impl: …`.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  @type delivery :: %{
          required(:scope) => Relay.Scope.t(),
          required(:delivery_id) => Relay.Id.t(),
          optional(atom()) => term()
        }
  @type decision :: {:send, String.t()} | {:skip, String.t(), String.t()} | {:error, :not_ready}

  @callback reevaluate(delivery()) :: decision()

  # TN-70 (2)
  @doc "Returns the configured lattice implementation."
  @spec impl() :: module()
  def impl do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, Relay.Policy.Lattice.Unavailable)
  end

  # TN-40
  # TN-70 (2)
  @doc "Re-evaluates one paused delivery through `impl`: `{:send, decision_ref}`, `{:skip, reason, rule_id}` or `{:error, :not_ready}`."
  @spec reevaluate(delivery(), module()) :: decision()
  def reevaluate(delivery, impl \\ impl()), do: impl.reevaluate(delivery)
end
