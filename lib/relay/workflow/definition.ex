defmodule Relay.Workflow.Definition do
  @moduledoc """
  A workflow definition is data (C-40, INV-48): a name, a tenant category, a fixed message class, the JSON Schema 2020-12 of its event data and a list of channel steps, each sending to one channel with one template key. Nothing in it is code that runs at send time. The digest of a definition is SHA-256 over its canonical JSON (keys sorted, no insignificant whitespace), because event schemas may carry numbers that have no deterministic CBOR form.

  The publication gate of stage 3 (`gate/1`) checks that the event schema builds as JSON Schema 2020-12 without remote references, that step keys are unique. Its findings are RFC 6901 field errors under `/definition`.
  """

  @dialect "https://json-schema.org/draft/2020-12/schema"

  @type t :: %{String.t() => term()}
  @type field_error :: %{pointer: String.t(), code: String.t(), detail: String.t()}

  # TN-65 (3)
  # WF-5
  @doc "The SHA-256 digest of a definition's canonical JSON."
  @spec digest(t()) :: <<_::256>>
  def digest(definition), do: :crypto.hash(:sha256, canonical_json(definition))

  @doc "Encodes a JSON value with its object keys sorted, so the same value has one encoding."
  @spec canonical_json(term()) :: iodata()
  def canonical_json(value), do: Jason.encode_to_iodata!(order(value))

  defp order(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, order(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp order(list) when is_list(list), do: Enum.map(list, &order/1)
  defp order(value), do: value

  # WF-1
  # API-27
  @doc "Builds the validator of a definition's event schema; a remote reference or another dialect is refused."
  @spec event_schema(map()) :: {:ok, JSV.Root.t()} | {:error, String.t()}
  def event_schema(%{} = schema) do
    cond do
      Map.get(schema, "$schema", @dialect) != @dialect ->
        {:error, "the event schema must be JSON Schema 2020-12"}

      remote_ref?(schema) ->
        {:error, "the event schema may only reference itself"}

      true ->
        case JSV.build(schema, default_meta: @dialect) do
          {:ok, root} -> {:ok, root}
          {:error, _reason} -> {:error, "the event schema is not a valid JSON Schema 2020-12"}
        end
    end
  end

  def event_schema(_schema), do: {:error, "the event schema must be an object"}

  defp remote_ref?(map) when is_map(map) do
    Enum.any?(map, fn
      {"$ref", ref} when is_binary(ref) -> not String.starts_with?(ref, "#")
      {"$dynamicRef", ref} when is_binary(ref) -> not String.starts_with?(ref, "#")
      {_key, value} -> remote_ref?(value)
    end)
  end

  defp remote_ref?(list) when is_list(list), do: Enum.any?(list, &remote_ref?/1)
  defp remote_ref?(_value), do: false

  # WF-1
  # WF-8
  # API-24
  @doc "Runs the publication gate over a definition and returns its field errors; none means it may be published."
  @spec gate(t()) :: [field_error()]
  def gate(definition) do
    schema_errors(definition) ++ step_errors(definition)
  end

  defp schema_errors(definition) do
    case event_schema(Map.get(definition, "event_schema")) do
      {:ok, _root} -> []
      {:error, detail} -> [error("/definition/event_schema", "invalid_format", detail)]
    end
  end

  defp step_errors(definition) do
    keys = definition |> Map.get("steps", []) |> Enum.map(& &1["key"])

    keys
    |> Enum.with_index()
    |> Enum.filter(fn {key, index} -> key in Enum.take(keys, index) end)
    |> Enum.map(fn {_key, index} ->
      error("/definition/steps/#{index}/key", "conflict", "step keys are unique")
    end)
  end

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  # WF-8
  @doc "The channel steps of a definition as `{key, channel, template}`."
  @spec steps(t()) :: [%{key: String.t(), channel: String.t(), template: String.t()}]
  def steps(definition) do
    for %{"type" => "channel"} = step <- Map.get(definition, "steps", []),
        do: %{key: step["key"], channel: step["channel"], template: step["template"]}
  end
end
