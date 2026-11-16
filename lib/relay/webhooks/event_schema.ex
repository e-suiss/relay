defmodule Relay.Webhooks.EventSchema do
  @moduledoc """
  The schema of a tenant event type (WH-13, WH-14), pure: a JSON Schema 2020-12 document of the event's data, the identifier fields that make up the thin payload, and an example. The schema is data and is only ever validated against; references resolve within the document and the bundled meta-schemas, never over the network, and no tenant code runs. Each identifier is a property the schema declares, and the example is valid against the schema. The digest is SHA-256 over the document written with sorted keys, so the same schema has the same digest however its keys were ordered.
  """

  @dialect "https://json-schema.org/draft/2020-12/schema"
  @max_bytes Relay.Limits.fetch!(["webhook", "event_schema_max_bytes"])

  @type reason :: :too_large | :not_a_schema | {:identifier, String.t()} | :example

  # WH-14
  @doc "Checks a schema with its identifiers and example; returns the schema's digest."
  @spec check(map(), [String.t()], map() | nil) :: {:ok, <<_::256>>} | {:error, reason()}
  def check(%{} = schema, identifiers, example) when is_list(identifiers) do
    canonical = canonical(schema)

    with :ok <- sized(canonical, example),
         {:ok, root} <- build(schema),
         :ok <- declared(schema, identifiers),
         :ok <- valid(root, example) do
      {:ok, :crypto.hash(:sha256, canonical)}
    end
  end

  defp sized(canonical, example) do
    if byte_size(canonical) <= @max_bytes and byte_size(canonical(example)) <= @max_bytes,
      do: :ok,
      else: {:error, :too_large}
  end

  defp build(%{"$schema" => dialect}) when dialect != @dialect, do: {:error, :not_a_schema}

  defp build(schema) do
    case JSV.build(schema, default_meta: @dialect) do
      {:ok, root} -> {:ok, root}
      {:error, _reason} -> {:error, :not_a_schema}
    end
  end

  defp declared(schema, identifiers) do
    properties = Map.get(schema, "properties", %{})

    case Enum.find(identifiers, &(not (is_map(properties) and is_map_key(properties, &1)))) do
      nil -> :ok
      missing -> {:error, {:identifier, missing}}
    end
  end

  defp valid(_root, nil), do: :ok

  defp valid(root, example) do
    case JSV.validate(example, root, cast: false) do
      {:ok, _example} -> :ok
      {:error, _error} -> {:error, :example}
    end
  end

  defp canonical(%{} = map) do
    members =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(",", &member/1)

    IO.iodata_to_binary(["{", members, "}"])
  end

  defp canonical(list) when is_list(list),
    do: IO.iodata_to_binary(["[", Enum.map_intersperse(list, ",", &canonical/1), "]"])

  defp canonical(value), do: Jason.encode!(value)

  defp member({key, value}), do: [Jason.encode!(key), ":", canonical(value)]
end
