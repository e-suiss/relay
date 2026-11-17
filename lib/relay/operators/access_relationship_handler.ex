defmodule Relay.Operators.AccessRelationshipHandler do
  @moduledoc """
  The relationship copy's handler of the Access `relationship.updated` event (AG-59, AG-73, Access E55): it records the level an agent holds towards another agent in one tenant environment (`Relay.Agents.relationship_changed/2`). An older or repeated sequence number of the pair changes nothing, and a pair whose agents are not both registered in the environment creates nothing. Registered as `config :relay, Relay.Access, relationship_handler: Relay.Operators.AccessRelationshipHandler`; the event consumer calls it once for each environment of the event's tenant and an error retries the event, so it is idempotent.
  """

  @behaviour Relay.Access.RelationshipHandler

  # AG-59
  # AG-73
  @impl Relay.Access.RelationshipHandler
  def handle_relationship(scope, relationship) do
    case Relay.Agents.relationship_changed(scope, relationship) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
