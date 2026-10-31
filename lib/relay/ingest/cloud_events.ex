defmodule Relay.Ingest.CloudEvents do
  @moduledoc """
  CloudEvents 1.0 intake (API-28 … API-31, MD-16): reading an event in binary mode from its `ce-*` headers and JSON body, the keys derived from `(source, id)`, and the mapping of an event to a native event through the tenant's type mapping: the recipient and sub-tenant pointers and the allow-list of data fields. Only the attributes of the contract are accepted (S-93); any other extension attribute is `unknown_field`, and `data` must be a JSON object.

  The keys are SHA-256 digests over deterministic CBOR, so personal data that a source or id may carry never appears in a key (S-65):

      idempotency key  "ce_" ‖ hex(SHA-256(det-CBOR(["relay.ce_idempotency.v1", source, id])))
      dedup key        "ce:" ‖ hex(SHA-256(det-CBOR(["relay.ce_dedup.v1", source, id])))
      batch key        "ce_" ‖ hex(SHA-256(det-CBOR(["relay.ce_batch_idempotency.v1", pairs])))
  """

  alias Relay.Ingest.Pointer

  @attributes ~w(id source type subject time datacontenttype dataschema traceparent tracestate)
  @header_attributes Enum.map(@attributes -- ["traceparent", "tracestate"], &("ce-" <> &1))

  # API-31
  @doc "The idempotency key derived from an event's source and id."
  @spec idempotency_key(String.t(), String.t()) :: String.t()
  def idempotency_key(source, id), do: "ce_" <> hex(["relay.ce_idempotency.v1", source, id])

  # API-28
  # API-16
  @doc "The dedup key derived from an event's source and id."
  @spec dedup_key(String.t(), String.t()) :: String.t()
  def dedup_key(source, id), do: "ce:" <> hex(["relay.ce_dedup.v1", source, id])

  # API-31
  @doc "The idempotency key of a CloudEvents batch: the digest of its `(source, id)` list."
  @spec batch_key([{String.t(), String.t()}]) :: String.t()
  def batch_key(pairs),
    do: "ce_" <> hex(["relay.ce_batch_idempotency.v1", Enum.map(pairs, fn {s, i} -> [s, i] end)])

  # API-28
  @doc "The digest of `(source, id)` stored with a CloudEvents event."
  @spec key_digest(String.t(), String.t()) :: <<_::256>>
  def key_digest(source, id), do: :crypto.hash(:sha256, Relay.Canonical.encode!([source, id]))

  defp hex(value),
    do: Base.encode16(:crypto.hash(:sha256, Relay.Canonical.encode!(value)), case: :lower)

  # API-28
  # API-28
  @doc "Reads a binary mode event from its request headers (lowercase names) and decoded JSON body."
  @spec from_binary([{String.t(), String.t()}], term()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def from_binary(headers, body) do
    ce = for {"ce-" <> _ = name, value} <- headers, into: %{}, do: {name, value}
    unknown = Map.keys(ce) -- ["ce-specversion" | @header_attributes]

    cond do
      unknown != [] ->
        {:error,
         Relay.Error.new(:unknown_field, "unknown CloudEvents attributes", %{
           errors: Enum.map(Enum.sort(unknown), &field("/headers/" <> &1, "not_allowed"))
         })}

      ce["ce-specversion"] != "1.0" ->
        failed([field("/headers/ce-specversion", "unsupported_value")])

      not is_map(body) ->
        failed([field("/data", "invalid_format")])

      true ->
        attributes = for {"ce-" <> name, value} <- ce, name != "specversion", do: {name, value}
        event = Map.new([{"specversion", "1.0"} | attributes])

        missing = for name <- ~w(id source type), not Map.has_key?(event, name), do: name

        if missing == [],
          do: {:ok, Map.put(event, "data", body)},
          else: failed(Enum.map(missing, &field("/headers/ce-" <> &1, "required")))
    end
  end

  # API-28
  # MD-16
  # API-25
  @doc "Maps an event to a native event request through a type mapping (`to_pointer`, `tenant_pointer`, `data_fields`)."
  @spec map_event(map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def map_event(event, mapping) do
    data = Map.get(event, "data", %{})

    case Pointer.get(data, mapping["to_pointer"]) do
      {:ok, to} ->
        projected = Pointer.project(data, mapping["data_fields"])
        request = %{"to" => List.wrap(to), "data" => projected}

        tenant =
          case mapping["tenant_pointer"] && Pointer.get(data, mapping["tenant_pointer"]) do
            {:ok, value} when is_binary(value) -> value
            _ -> nil
          end

        {:ok, if(tenant, do: Map.put(request, "tenant", tenant), else: request)}

      :error ->
        failed([field("/data" <> mapping["to_pointer"], "required")])
    end
  end

  defp failed(errors) do
    {:error, Relay.Error.new(:validation_failed, "the CloudEvent is invalid", %{errors: errors})}
  end

  defp field(pointer, code), do: %{pointer: pointer, code: code, detail: "CloudEvents attribute"}
end
