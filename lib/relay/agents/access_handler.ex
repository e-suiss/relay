defmodule Relay.Agents.AccessHandler do
  @moduledoc """
  The agent records' handler of Access agent lifecycle events (E-29, AG-5): `agent.suspended` and `agent.deleted` stop delivery to the agent bound to the event's Access Party and the agent's own requests, and `agent.reactivated` lifts a suspension (`Relay.Agents.Registry.access_changed/4`). The agent's mailbox is suspended with it and never deleted (AG-23, INV-47). Registered in `config :relay, Relay.Access, agent_handlers: [...]`; the event consumer calls it once for each environment of the event's tenant and an error retries the event, so it is idempotent.
  """

  @behaviour Relay.Access.AgentHandler

  alias Relay.Agents.Registry

  # E-29
  # AG-5
  # INV-47
  @impl Relay.Access.AgentHandler
  def handle_agent_event(scope, kind, subject, event_ref),
    do: Registry.access_changed(scope, kind, subject, event_ref)
end
