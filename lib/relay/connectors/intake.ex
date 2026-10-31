defmodule Relay.Connectors.Intake do
  @moduledoc """
  The acceptance of one connector message (T-41). A message is one structured mode CloudEvent and takes the same path as `POST /v1/events` with `application/cloudevents+json`: the connector's API client trace stands for the caller (`Relay.Access.connector_principal/2`), the tenant must be active and needs no certificate-bound token (INV-42, API-48), the tenant's API rate limit is spent, the event is checked against the request schema, mapped through the tenant's type mapping and prepared (`Relay.Api.CloudEvent.prepare/2`), admission control is asked (T-35), and the event is accepted inside an idempotency transaction (`Relay.Api.Idempotency.run/5`, INV-2). The idempotency key is derived from the event's `(source, id)` as on the HTTP entry (API-31) and kept per connector (`CONNECTOR <name>`); `(tenant, source, id)` is the dedup key (API-16), so a message the source delivers again opens no second notification.

  The outcome tells the pipeline what to do with the message:

  * `{:accepted, :fresh | :replayed}`: the event is durably accepted; the message is acknowledged.
  * `{:retry, wait_ms, error}`: nothing was accepted and the same message must be tried again after `wait_ms`: a retryable error (`retryable` in the error catalog, such as `rate_limited` or `service_unavailable`), an error outside the catalog, or a refusal of the connector's own standing (unknown, revoked or under-scoped client, suspended tenant), which waits the connector's hold time. The message is never acknowledged meanwhile, so the source keeps it.
  * `{:rejected, error}`: the message can never be accepted as it is (malformed, unmapped type, validation, exhausted quota); the message is failed with the error code.
  """

  alias Relay.Api.CloudEvent
  alias Relay.Api.ErrorCatalog
  alias Relay.Api.Events
  alias Relay.Api.Idempotency
  alias Relay.Api.RateLimit
  alias Relay.Api.Schema
  alias Relay.Api.Tenant
  alias Relay.Connectors.Connector

  @operation "createEvent"
  @media "application/cloudevents+json"
  @body_bytes Relay.Limits.fetch!(["connector_message_max_bytes"])
  @lanes [:l1, :l2, :l3]
  @hold [
    :auth_invalid_token,
    :auth_revoked_client,
    :auth_tenant_suspended,
    :auth_insufficient_scope,
    :auth_environment_mismatch
  ]

  @type outcome ::
          {:accepted, :fresh | :replayed}
          | {:retry, pos_integer(), Relay.Error.t()}
          | {:rejected, Relay.Error.t()}

  # T-41
  # INV-2
  # API-16
  # API-31
  @doc "Accepts one message of `connector`; see the module documentation."
  @spec run(Connector.t(), term()) :: outcome()
  def run(%Connector{} = connector, data) do
    connector
    |> accept(data)
    |> classify(connector)
  end

  defp accept(connector, data) do
    with {:ok, raw, event} <- decode(data),
         {:ok, principal} <- principal(connector),
         {:ok, _edge} <- tenant(principal),
         :ok <- Schema.validate_request(@operation, @media, event),
         ctx = context(principal),
         {:ok, prepared} <- CloudEvent.prepare(ctx, event),
         :ok <- admission(prepared),
         {:ok, key} <- key(event) do
      endpoint = "CONNECTOR " <> Atom.to_string(connector.name)
      work = fn _status -> stored(Events.accept(prepared, ctx)) end

      case Idempotency.run(principal.scope, endpoint, key, raw, work) do
        {:ok, {kind, _response}} -> {:accepted, kind}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode(data) when is_binary(data) and byte_size(data) > @body_bytes do
    {:error,
     Relay.Error.new(:payload_too_large, "the message exceeds #{@body_bytes} bytes", %{
       limit: @body_bytes,
       actual: byte_size(data),
       limit_name: "body_bytes"
     })}
  end

  defp decode(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = event} -> {:ok, data, event}
      _ -> {:error, Relay.Error.new(:malformed_request, "the message is not a JSON CloudEvent")}
    end
  end

  defp decode(_data),
    do: {:error, Relay.Error.new(:malformed_request, "the message is not a JSON CloudEvent")}

  # API-71
  # API-43
  defp principal(%{access_tenant_id: tenant, access_client_id: client}) do
    required = Relay.Api.Contract.operation!(@operation).scopes

    with {:ok, principal} <- Relay.Access.connector_principal(tenant, client) do
      if required == [] or Enum.any?(required, &(&1 in principal.scopes)),
        do: {:ok, principal},
        else: {:error, insufficient_scope()}
    end
  end

  defp insufficient_scope,
    do: Relay.Error.new(:auth_insufficient_scope, "the API client lacks the scope")

  # INV-42
  # API-48
  # API-50
  defp tenant(principal) do
    with {:ok, edge} <- Tenant.edge(principal.scope),
         :ok <- active(edge),
         {:ok, _report} <- spend(principal, edge) do
      {:ok, edge}
    end
  end

  defp active(%{status: :active, mtls_required: false}), do: :ok

  defp active(%{status: :active}),
    do: {:error, Relay.Error.new(:auth_invalid_token, "the tenant needs bound tokens")}

  defp active(_edge),
    do: {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}

  defp spend(principal, edge) do
    case RateLimit.check(principal.scope, RateLimit.tiers(edge.rate_settings), 1) do
      {:ok, report} -> {:ok, report}
      {:error, error, _report} -> {:error, error}
    end
  end

  defp context(principal) do
    ref = principal.api_client_id
    {:ok, actor} = Relay.Actor.new(:api_client, ref, ref)

    %{
      scope: principal.scope,
      actor: actor,
      api_client_id: principal.api_client_id,
      subtenant_id: principal.subtenant_id,
      traceparent: nil
    }
  end

  # T-35
  # API-51
  defp admission(prepared) do
    {class, channels} = Events.admission(prepared)

    input = %{
      message_class: class,
      channels: channels,
      shed: Map.new(@lanes, &{&1, Relay.Platform.load_shed_engaged?(&1)}),
      breaker_open: MapSet.new(),
      lane_capacity: Relay.Platform.lane_capacity()
    }

    case Relay.Platform.admit(input) do
      :admit ->
        :ok

      {:reject, %{retry_after_s: retry, rule_id: rule}} ->
        message = "Relay is overloaded (#{rule})"
        {:error, Relay.Error.new(:service_unavailable, message, %{retry_after: retry})}
    end
  end

  defp key(event) do
    case CloudEvent.derived_key(@media, event, []) do
      {:ok, key} -> {:ok, key}
      :none -> {:error, Relay.Error.new(:validation_failed, "the event has no source and id")}
    end
  end

  defp stored({:ok, body}),
    do: {:ok, {202, [{"content-type", "application/json"}], Jason.encode!(body)}}

  defp stored({:error, error}), do: {:error, error}

  defp classify({:accepted, kind}, _connector), do: {:accepted, kind}

  defp classify({:error, %Relay.Error{code: code} = error}, connector) when code in @hold,
    do: {:retry, connector.hold_ms, error}

  defp classify({:error, %Relay.Error{code: code} = error}, _connector) do
    case ErrorCatalog.fetch(code) do
      {:ok, %{retryable: false}} -> {:rejected, error}
      _retryable_or_unknown -> {:retry, wait_ms(error), error}
    end
  end

  defp wait_ms(%Relay.Error{details: %{retry_after: seconds}}) when is_integer(seconds),
    do: max(seconds, 1) * 1000

  defp wait_ms(_error), do: 1000
end
