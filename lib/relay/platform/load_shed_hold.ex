defmodule Relay.Platform.LoadShed.Hold do
  @moduledoc """
  The port through which load shedding records a postponed delivery. An implementation writes the `delivery.held` ledger event with the shedding rule and the time the delivery is held until, in the delivery's tenant scope, and reports `:held`, or `:already_terminal` / `:not_found` for a delivery that no longer waits. The default implementation is `Relay.Platform.LoadShed.HoldStore`; `config :relay, Relay.Platform.LoadShed, hold: module` replaces it.
  """

  @type result :: :held | :already_terminal | :not_found

  # T-34 (4)
  @callback hold(Relay.Scope.t(), Relay.Id.t(), rule_id :: String.t(), until :: DateTime.t()) ::
              {:ok, result()} | {:error, term()}
end
