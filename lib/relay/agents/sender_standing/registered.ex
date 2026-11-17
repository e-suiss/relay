defmodule Relay.Agents.SenderStanding.Registered do
  @moduledoc """
  The standing of a sender by the block list and the first contact rate of registered agents (AG-59, AG-60, AG-61, AG-69; `Relay.Agents.FirstContact`). A sender that is an agent of the scope, named by its agent identifier, is blocked when the recipient agent blocked it, and over the first contact rate when it is at its first contact limits and the recipient holds no relationship level above `unknown` towards it. Any other sender or recipient has no block list and no first contact rate: neither holds.
  """

  @behaviour Relay.Agents.SenderStanding

  alias Relay.Agents.FirstContact

  @none %{blocked: false, over_first_contact_rate: false}

  # AG-69
  @impl Relay.Agents.SenderStanding
  def standing(scope, {:agent, recipient_id}, %{kind: :agent, id: id}) when is_binary(id) do
    case Relay.ExternalId.decode(id, ["agt"]) do
      {:ok, sender_id} -> read(scope, recipient_id, sender_id)
      {:error, _error} -> {:ok, @none}
    end
  end

  def standing(_scope, _recipient, _sender), do: {:ok, @none}

  defp read(scope, recipient_id, sender_id) do
    with {:ok, standing} <- FirstContact.standing(scope, recipient_id, sender_id) do
      over = standing.over_first_contact_rate and standing.relationship == :unknown
      {:ok, %{blocked: standing.blocked, over_first_contact_rate: over}}
    end
  end
end
