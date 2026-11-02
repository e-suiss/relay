defmodule Relay.Policy.Lattice do
  @moduledoc """
  The policy lattice port: preference, İYS, quiet hours, frequency and quota decide again whether a paused delivery may go (TN-40). Resuming a kill switch or lifting a suspension passes every delivery through it. The implementation is `Relay.Policy.Live`, the lattice at run time (PC-58 (2), TN-70 (2)); `Relay.Policy.Lattice.Unavailable`, which is never ready, refuses every resume, and the live lattice answers the same while an input of the decision cannot be read (INV-43). The implementation is configured as `config :relay, Relay.Policy.Lattice, impl: …`.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  @type delivery :: %{
          required(:scope) => Relay.Scope.t(),
          required(:delivery_id) => Relay.Id.t(),
          optional(atom()) => term()
        }
  @type decision ::
          {:send, String.t()}
          | {:skip, String.t(), String.t()}
          | {:defer, String.t(), String.t(), DateTime.t()}
          | {:expire, String.t()}
          | {:pause, String.t()}
          | {:error, :not_ready}

  @callback reevaluate(delivery()) :: decision()

  # TN-70 (2)
  # PC-58 (2)
  @doc "Returns the configured lattice implementation, `Relay.Policy.Live` unless configured otherwise."
  @spec impl() :: module()
  def impl do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, Relay.Policy.Live)
  end

  # TN-40
  # TN-70 (2)
  @doc "Re-evaluates one paused delivery through `impl`: `{:send, decision_ref}`, `{:skip, reason, rule_id}`, `{:defer, reason, rule_id, deferred_until}` (the delivery job records the deferral when it runs), `{:expire, rule_id}`, `{:pause, rule_id}` (a kill switch in force still holds it) or `{:error, :not_ready}`."
  @spec reevaluate(delivery(), module()) :: decision()
  def reevaluate(delivery, impl \\ impl()), do: impl.reevaluate(delivery)
end
