defmodule Relay.Agents.SenderStanding.None do
  @moduledoc """
  The sender standing of an installation without a block list and without a first contact rate (AG-69): no sender is blocked and none is over the rate.
  """

  @behaviour Relay.Agents.SenderStanding

  # AG-69
  @impl Relay.Agents.SenderStanding
  def blocked?(_scope, _recipient, _sender), do: false

  # AG-69
  @impl Relay.Agents.SenderStanding
  def over_first_contact_rate?(_scope, _recipient, _sender), do: false
end
