defmodule Relay.Access.RelationshipHandler do
  @moduledoc """
  The behaviour of the consumer of the Access `relationship.updated` event (AG-59, AG-73, Access E55): the copy of the relationship level a person's agent holds towards another agent. The handler is named in `config :relay, Relay.Access, relationship_handler: module` and is called by the event consumer, outside any transaction, once for each environment of the mapped tenant.

  The relationship carries `:owner` and `:peer` (the Access Party references of the agent that holds the level and of the agent it is about, each the pairwise `sub` of that agent's tokens in Relay's sector), `:level` (`unknown`, `known`, `verified` or `trusted`), `:sequence` (monotone for the pair) and `:source_event_ref` (the event's SET `jti`). The level is a policy input and never an authority.
  """

  @doc "Handles a relationship level in one tenant environment; `{:rejected, reason}` marks the event rejected and an error retries it."
  @callback handle_relationship(scope :: Relay.Scope.t(), relationship :: map()) ::
              :ok | {:rejected, String.t()} | {:error, term()}
end
