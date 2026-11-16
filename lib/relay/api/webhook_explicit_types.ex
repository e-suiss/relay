defmodule Relay.Api.WebhookExplicitTypes do
  @moduledoc """
  The subscription of a webhook endpoint to an event type that `*` does not cover, on the operator surface (WH-67, WH-16, TN-50). The audit records of a tenant flow to an endpoint only when its selection names `audit_record.appended`. Choosing that needs what reading the audit log needs, a tenant administrator's operator session, which the operator pipeline checked before this runs; an API client and the webhook portal cannot add the type. The change is the endpoint's own and is audited as `webhook_endpoint.updated`; removing the type again is an ordinary change of the endpoint.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Webhooks

  @type answer :: {:ok, {pos_integer(), map()}} | {:error, Relay.Error.t()}

  # WH-67
  # WH-48
  @doc "Adds the explicit-only event type the body names to the selection of an endpoint of use `relay_events`; `200` with the endpoint. A type that `*` covers is a field error: it is chosen on the server API."
  @spec subscribe(Relay.Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def subscribe(%Relay.Scope{} = scope, id, %{"event_type" => type}, actor) do
    if Relay.EventCatalog.explicit_only?(type) do
      digest = Gate.digest(scope, "webhook_endpoint.updated", Relay.Id.to_string(id))
      answer(Relay.Webhooks.endpoint_subscribe_explicit(scope, id, type, digest, actor))
    else
      {:error, field("not an event type that needs this operation")}
    end
  end

  defp answer({:ok, {result, %{} = endpoint}}) when result in [:updated, :unchanged],
    do: {:ok, {200, Webhooks.view(endpoint)}}

  defp answer({:ok, {refused, _endpoint}}), do: {:error, refused(refused)}

  defp answer({:error, _reason}),
    do: {:error, Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})}

  defp refused(:not_found),
    do: Relay.Error.new(:webhook_endpoint_not_found, "no such webhook endpoint")

  defp refused(:archived),
    do: Relay.Error.new(:webhook_endpoint_archived, "the endpoint is archived")

  defp refused(:not_relay_events),
    do: field("only an endpoint of use relay_events receives Relay's events")

  defp refused(:limit_reached),
    do: Gate.field_error("/event_type", "too_long", "the endpoint names no more event types")

  defp refused(_conflict),
    do: Relay.Error.new(:resource_conflict, "the endpoint changed; try again")

  defp field(detail), do: Gate.field_error("/event_type", "not_allowed", detail)
end
