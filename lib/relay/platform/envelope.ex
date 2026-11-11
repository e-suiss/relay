defmodule Relay.Platform.Envelope do
  @moduledoc """
  The CloudEvents 1.0 envelope of an outbox event in use A (WH-1, E-85). `source` is the installation `issuer`; the envelope carries the `accesstenant` extension (the Access tenant bound to the Relay tenant), `accessorganization` when the event names a sub-tenant bound to an Access organization, and `correlationid` when the sender gave a `correlation_id` (absent otherwise). The data keeps its thin shape (WH-11) with the internal identifiers written as prefixed external identifiers (API-72); `recipient_kind` only chooses the recipient prefix and never leaves the envelope.
  """

  alias Relay.ExternalId
  alias Relay.Platform.OutboxStore

  @prefixes %{
    "notification_id" => "ntf",
    "delivery_id" => "dlv",
    "event_id" => "evt",
    "tenant" => "stn",
    "device_id" => "dev",
    "kill_switch_id" => "ksw"
  }

  @type context :: %{
          required(:issuer) => String.t(),
          required(:environment) => String.t(),
          required(:access_tenant) => String.t() | nil,
          optional(:access_organization) => String.t() | nil,
          optional(:correlation_id) => String.t() | nil
        }

  # E-85
  # WH-1
  @doc "Reads the envelope context of an outbox event inside the caller's scoped transaction: the Access tenant, the Access organization of the event's sub-tenant and the sender's correlation identifier of its notification."
  @spec context(OutboxStore.event(), String.t()) :: context()
  def context(%{payload: payload}, issuer) when is_binary(issuer) do
    row = OutboxStore.envelope_context(payload["tenant"], payload["notification_id"])

    %{
      issuer: String.trim_trailing(issuer, "/"),
      environment: row["environment"],
      access_tenant: row["access_tenant_id"],
      access_organization: row["access_organization_id"],
      correlation_id: row["correlation_id"]
    }
  end

  # E-85
  # WH-1
  @doc "Builds the CloudEvents envelope of an outbox event from its context."
  @spec build(OutboxStore.event(), context()) :: map()
  def build(event, context) do
    %{
      "specversion" => "1.0",
      "id" => ExternalId.encode("oev", event.id),
      "source" => context.issuer,
      "type" => event.event_type,
      "time" => DateTime.to_iso8601(event.created_at),
      "datacontenttype" => "application/json",
      "seq" => event.seq,
      "environment" => context.environment,
      "data" => data(event.payload)
    }
    |> put("traceparent", event.traceparent)
    |> put("accesstenant", context.access_tenant)
    |> put("accessorganization", Map.get(context, :access_organization))
    |> put("correlationid", Map.get(context, :correlation_id))
  end

  # API-72
  @doc "The thin data of an outbox payload with prefixed external identifiers."
  @spec data(map()) :: map()
  def data(payload) do
    {kind, payload} = Map.pop(payload, "recipient_kind")

    Map.new(payload, fn {key, value} -> {key, external(key, value, kind)} end)
  end

  defp external("recipient_id", id, kind) when is_binary(id), do: encode(recipient(kind), id)

  defp external(key, id, _kind) when is_map_key(@prefixes, key) and is_binary(id),
    do: encode(Map.fetch!(@prefixes, key), id)

  defp external(_key, value, _kind), do: value

  defp recipient("agent"), do: "agt"
  defp recipient(_subscriber), do: "sub"

  defp encode(prefix, id) do
    case Relay.Id.parse(id) do
      {:ok, uuid} -> ExternalId.encode(prefix, uuid)
      {:error, _error} -> id
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
