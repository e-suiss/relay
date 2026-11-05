defmodule Relay.Api.Discovery do
  @moduledoc """
  The Relay discovery document (`GET /.well-known/relay-configuration`) and the product event key set (`GET /.well-known/relay-jwks.json`). The document is one per installation and carries no tenant data: the installation's base URL as `issuer`, the API base, the data region, the bound Access issuer, Relay's own Access `client_id` (the sector of subscriber `sub` values, E-90), the dated contract versions, the key set's address and the capabilities served now.

  A capability names the contract operations that serve it; it and its endpoint appear in the document only while every one of them is served, so the document never promises an operation that is not routed. The product event capability appears only while the key set holds a key; no product event key is in use yet, so the set is empty.
  """

  alias Relay.Api.Contract

  @capabilities [
    {"urn:suiss:relay:events:1", "events_endpoint", "/v1/events",
     ~w(createEvent createEventBatch getEvent cancelEvent cancelEventsByKey)},
    {"urn:suiss:relay:waitpoint:1", "waitpoints_endpoint", "/v1/waitpoints",
     ~w(createWaitpoint getWaitpoint listWaitpoints cancelWaitpoint heartbeatWaitpoint)},
    {"urn:suiss:relay:escalation:1", "escalation_policies_endpoint", "/v1/escalation_policies",
     ~w(putEscalationPolicy getEscalationPolicy listEscalationPolicies listEscalationPolicyVersions archiveEscalationPolicy)},
    {"urn:suiss:relay:agent_ceiling:1", "agents_endpoint", "/v1/agents",
     ~w(createAgentCeilingDecision resumeAgent)},
    {"urn:suiss:relay:webhook_endpoints:1", "webhook_endpoints_endpoint", "/v1/webhook_endpoints",
     ~w(createWebhookEndpoint listWebhookEndpoints getWebhookEndpoint updateWebhookEndpoint archiveWebhookEndpoint rotateWebhookEndpointKey)}
  ]
  @product_events "urn:suiss:relay:product_events:1"

  for {_urn, _field, _path, ids} <- @capabilities, id <- ids, do: Contract.operation!(id)

  @jwks_path Contract.operation!("getRelayJwks").path

  @type capability :: %{
          urn: String.t(),
          field: String.t(),
          path: String.t(),
          operations: [String.t()]
        }

  # E-81
  @doc "Every capability with its endpoint field, its path under the issuer and the operations that serve it."
  @spec capabilities() :: [capability()]
  def capabilities do
    for {urn, field, path, ids} <- @capabilities,
        do: %{urn: urn, field: field, path: path, operations: ids}
  end

  # E-81
  # API-52
  # INV-41
  @doc "The discovery document for the installation at `base_url`, listing the capabilities whose operations are all in `served`."
  @spec configuration(String.t(), Enumerable.t()) :: map()
  def configuration(base_url, served) when is_binary(base_url) do
    issuer = String.trim_trailing(base_url, "/")
    served = MapSet.new(served)
    offered = Enum.filter(capabilities(), fn c -> Enum.all?(c.operations, &(&1 in served)) end)
    product_events = if Enum.empty?(jwks()["keys"]), do: [], else: [@product_events]
    versions = Contract.api_versions()

    offered
    |> Map.new(&{&1.field, issuer <> &1.path})
    |> Map.merge(%{
      "issuer" => issuer,
      "api_base" => issuer <> "/v1",
      "region" => Relay.Datasets.installation_region(),
      "access_issuer" => Relay.Access.issuer(),
      "access_client_id" => Relay.Access.client_id(),
      "contract_version" => versions.latest,
      "contract_versions_supported" => versions.supported,
      "jwks_uri" => issuer <> @jwks_path,
      "capabilities" => Enum.map(offered, & &1.urn) ++ product_events
    })
  end

  # E-89
  @doc "The product event key set: the public Ed25519 keys that sign product events, as JWKs. Empty while no product event key is in use."
  @spec jwks() :: %{String.t() => [map()]}
  def jwks, do: %{"keys" => []}
end
