defmodule Relay.Platform.LoadShed.HoldStore do
  @moduledoc """
  The default `Relay.Platform.LoadShed.Hold`: `relay_fn.delivery_hold(p_delivery_id, p_rule_id, p_until)` in the delivery's own scoped transaction. The function writes only the `delivery.held` ledger event; the delivery projection does not change.
  """

  @behaviour Relay.Platform.LoadShed.Hold

  alias Relay.Repo

  @results [:held, :already_terminal, :not_found]

  # T-34 (4)
  @impl Relay.Platform.LoadShed.Hold
  def hold(scope, delivery_id, rule_id, until) do
    Repo.in_scope(scope, fn _status ->
      [%{"delivery_hold" => result}] =
        Repo.call!("relay_fn.delivery_hold", [delivery_id, rule_id, until])

      Repo.code!(result, @results)
    end)
  end
end
