defmodule Relay.Connectors do
  @moduledoc """
  Ingest connectors (T-41): Broadway pipelines that take a producer's events from its own outbox table, Kafka or SQS and accept them through the same path as `POST /v1/events` (`Relay.Connectors.Intake`). Broadway is used only here; its rate limiting is never used for a provider limit.

  Connectors are installation configuration (`Relay.Connectors.Connector`) and run on worker nodes. Without a configured connector nothing starts, and no source needs a component beyond PostgreSQL and Valkey to boot (T-7). Other contexts use only the functions of this module.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Api, Relay.Access, Relay.Platform],
    exports: []

  alias Relay.Connectors.Connector
  alias Relay.Connectors.Intake
  alias Relay.Connectors.Pipeline

  # T-41
  # T-7
  # INV-46
  @doc "Supervised children: one pipeline per configured connector on a worker node, none elsewhere. An invalid configuration raises `Relay.Config.Error` and stops the node."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    connectors = Connector.configured()

    if Relay.Role.enabled?(:worker),
      do: Enum.map(connectors, &child_spec/1),
      else: []
  end

  @doc "The child specification of a connector's pipeline."
  @spec child_spec(Connector.t()) :: Supervisor.child_spec()
  def child_spec(%Connector{} = connector) do
    %{
      id: {Pipeline, connector.name},
      start: {Pipeline, :start_link, [connector]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  # T-41
  @doc "Accepts one message of a connector; see `Relay.Connectors.Intake.run/2`."
  @spec accept(Connector.t(), term()) :: Intake.outcome()
  defdelegate accept(connector, data), to: Intake, as: :run
end
