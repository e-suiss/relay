defmodule Relay.Webhooks.Destination.AzureEventGrid do
  @moduledoc """
  The Azure Event Grid destination (WH-17): one `POST` of the event to the endpoint of a topic that takes the CloudEvents schema, through the egress boundary (WH-43). Success is the 2xx answer (WH-18).

  Configuration: `:endpoint` (the topic endpoint) and either `:managed_identity_client_id` or the access key of the topic as `:credential`. An endpoint without a query is called with the API version of custom topics; an endpoint that names its own version is called as it is.

  The event travels in structured mode, the only mode Event Grid takes (WH-8 (3)); the CloudEvents `id` inside it is the key a subscriber deduplicates on (WH-18). With an access key the request carries it in `aeg-sas-key`; with a managed identity it carries the bearer token of `Relay.Webhooks.Destination.Azure`. Neither appears in a failure or in a receipt (WH-19).
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Azure
  alias Relay.Webhooks.Destination.Cloud

  @api_version "api-version=2018-01-01"
  @resource "https://eventgrid.azure.net"
  @key ~r/\A[\x21-\x7E]+\z/

  # WH-17
  # WH-18
  @impl Relay.Webhooks.Destination
  def deliver(%{endpoint: endpoint} = config, prepared, opts)
      when is_binary(endpoint) and is_list(opts) do
    with {:ok, authorization} <- authorization(config, opts) do
      request = %{
        method: "POST",
        url: url(endpoint),
        headers: [{"content-type", prepared.content_type} | authorization],
        body: prepared.body
      }

      opts |> Cloud.request(request) |> Cloud.settle()
    end
  end

  def deliver(_config, _prepared, _opts), do: Cloud.invalid("endpoint_invalid")

  defp url(endpoint) do
    if String.contains?(endpoint, "?"), do: endpoint, else: endpoint <> "?" <> @api_version
  end

  # WH-17
  # WH-19
  defp authorization(config, opts) do
    client_id = Map.get(config, :managed_identity_client_id)
    credential = Map.get(config, :credential)

    cond do
      is_binary(client_id) -> Azure.bearer(client_id, @resource, opts)
      Redacted.redacted?(credential) -> access_key(Redacted.expose(credential))
      true -> Cloud.invalid("credentials_missing")
    end
  end

  defp access_key(key) do
    if is_binary(key) and Regex.match?(@key, key),
      do: {:ok, [{"aeg-sas-key", key}]},
      else: Cloud.invalid("access_key_invalid")
  end
end
