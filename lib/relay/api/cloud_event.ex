defmodule Relay.Api.CloudEvent do
  @moduledoc """
  CloudEvents on the send entry (API-28 … API-31): an event in binary or structured mode, or one row of a batch, is resolved through the tenant's type mapping (`422 event_type_not_mapped` without one, API-29) to a native event request, checked against the native request schema and prepared like any other event. `(tenant, source, id)` is its dedup key and `traceparent` travels with it.
  """

  alias Relay.Api.Events
  alias Relay.Api.Schema

  # API-28
  # API-29
  # MD-16
  @doc "Prepares a CloudEvent (its decoded attributes and `data`) as a native event."
  @spec prepare(Events.context(), map()) :: {:ok, Events.prepared()} | {:error, Relay.Error.t()}
  def prepare(%{scope: scope} = ctx, event) do
    with {:ok, mapping} <- mapping(scope, event),
         {:ok, key} <- workflow(scope, mapping),
         {:ok, native} <- Relay.Ingest.ce_map(event, mapping),
         native = Map.put(native, "workflow", key),
         :ok <- Schema.validate_request("createEvent", "application/json", native) do
      Events.prepare(ctx, native,
        source: :cloudevents,
        cloudevent: event,
        dedup_key: Relay.Access.dedup_key(event["source"], event["id"])
      )
    end
  end

  defp mapping(scope, event) do
    read = fn _status -> Relay.Ingest.mapping_resolve(event["type"], event["source"]) end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, %{} = mapping} -> {:ok, mapping}
      {:ok, nil} -> {:error, Relay.Error.new(:event_type_not_mapped, "no mapping for this type")}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp workflow(scope, mapping) do
    case Relay.Workflow.resolve_published_id(scope, mapping["workflow_id"]) do
      {:ok, {:ok, workflow}} ->
        {:ok, workflow["key"]}

      {:ok, :not_published} ->
        {:error,
         Relay.Error.new(:workflow_not_published, "the mapped workflow has no published version")}

      {:ok, :not_found} ->
        {:error, Relay.Error.new(:event_type_not_mapped, "the mapped workflow is gone")}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # API-28
  @doc "Reads a binary mode CloudEvent from the request headers and its JSON body."
  @spec from_binary([{String.t(), String.t()}], term()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate from_binary(headers, body), to: Relay.Ingest, as: :ce_from_binary

  # API-31
  @doc "The idempotency key a CloudEvents request derives when it has no `Idempotency-Key` header: from `(source, id)` of the event, or of every event of a batch; `:none` for any other body."
  @spec derived_key(String.t() | nil, term(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | :none
  def derived_key("application/cloudevents+json", %{"source" => s, "id" => i}, _headers)
      when is_binary(s) and is_binary(i),
      do: {:ok, Relay.Ingest.ce_idempotency_key(s, i)}

  def derived_key("application/cloudevents-batch+json", events, _headers) when is_list(events) do
    pairs = for %{"source" => s, "id" => i} <- events, is_binary(s) and is_binary(i), do: {s, i}

    if pairs != [] and length(pairs) == length(events),
      do: {:ok, Relay.Ingest.ce_batch_key(pairs)},
      else: :none
  end

  def derived_key("application/json", _body, headers) do
    case {List.keyfind(headers, "ce-source", 0), List.keyfind(headers, "ce-id", 0)} do
      {{_, source}, {_, id}} -> {:ok, Relay.Ingest.ce_idempotency_key(source, id)}
      _ -> :none
    end
  end

  def derived_key(_media, _body, _headers), do: :none

  defp unavailable do
    message = "the type mapping could not be read"
    Relay.Error.new(:service_unavailable, message, %{retry_after: 1})
  end
end
