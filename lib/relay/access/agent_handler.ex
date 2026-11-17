defmodule Relay.Access.AgentHandler do
  @moduledoc """
  The behaviour of a consumer of Access agent lifecycle events (E-29, AG-5, E-104): the agent records stop delivery to a suspended or deleted agent and the agent's own requests, and lift the suspension of a reactivated one; `party.disabled` reaches them as a suspension. Handlers are listed in `config :relay, Relay.Access, agent_handlers: [module]` and are called by the event consumer, outside any transaction, once for each environment of the event's tenant, with the agent's Access Party as Access events name it (the unpadded base64url of its 16 bytes) and the Access event's SET `jti`.
  """

  @doc "Handles an agent event in one tenant environment; an error retries the event."
  @callback handle_agent_event(
              scope :: Relay.Scope.t(),
              kind :: :suspended | :reactivated | :deleted,
              subject :: String.t(),
              event_ref :: String.t()
            ) :: :ok | {:error, term()}
end
