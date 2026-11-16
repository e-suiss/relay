defmodule Relay.EventCatalog do
  @moduledoc """
  Relay's event catalog as code reads it, taken at compile time from the `tenantWebhooks` channel of `contracts/asyncapi/events.yaml` (WH-14, WH-53). That channel is the definitive list of the event types Relay delivers to a tenant's endpoints: an endpoint subscribes only to names of this list, and an event type that is not in it is never delivered. The contract file is the single source; no event name is written anywhere else.
  """

  @path Path.expand("../../contracts/asyncapi/events.yaml", __DIR__)
  @external_resource @path

  document = YamlElixir.read_from_file!(@path)
  messages = document["components"]["messages"]

  entries =
    for {key, _reference} <- document["channels"]["tenantWebhooks"]["messages"] do
      message = Map.fetch!(messages, key)
      [_envelope, %{"properties" => %{"data" => data}}] = message["payload"]["schema"]["allOf"]

      %{
        name: message["name"],
        summary: message["summary"],
        version: message["x-relay-schema-version"],
        data: data,
        snapshot_only: Map.get(message, "x-relay-snapshot-only", [])
      }
    end

  @entries Map.new(entries, &{&1.name, &1})
  @schemas document["components"]["schemas"]
  @names @entries |> Map.keys() |> Enum.sort()

  @type entry :: %{
          name: String.t(),
          summary: String.t(),
          version: pos_integer(),
          data: map(),
          snapshot_only: [String.t()]
        }

  # WH-53
  @doc "The event names a tenant's endpoint can receive, sorted."
  @spec names() :: [String.t(), ...]
  def names, do: @names

  # WH-53
  @doc "Whether `name` is an event type Relay delivers to tenant endpoints."
  @spec delivered?(term()) :: boolean()
  def delivered?(name), do: is_map_key(@entries, name)

  # WH-11
  @doc "The fields of the thin payload of an event name: the identifiers its data schema declares, without the fields the catalog marks `x-relay-snapshot-only`, which reach an endpoint only through its snapshot allow-list (WH-12)."
  @spec identifiers(String.t()) :: {:ok, [String.t()]} | :error
  def identifiers(name) do
    with {:ok, fields} <- fields(name),
         do: {:ok, fields -- Map.fetch!(@entries, name).snapshot_only}
  end

  # WH-12
  # WH-53
  @doc "Every field the data schema of an event name declares; nothing outside it is ever delivered."
  @spec fields(String.t()) :: {:ok, [String.t()]} | :error
  def fields(name) do
    case Map.fetch(@entries, name) do
      {:ok, %{data: data}} -> {:ok, properties(data)}
      :error -> :error
    end
  end

  defp properties(%{"$ref" => "#/components/schemas/" <> key}),
    do: @schemas |> Map.fetch!(key) |> properties()

  defp properties(data), do: data |> Map.get("properties", %{}) |> Map.keys()

  # WH-14
  @doc "The catalog entry of an event name: its summary, the version of its data schema and the schema itself."
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(name), do: Map.fetch(@entries, name)
end
