defmodule Relay.Connectors.Connector do
  @moduledoc """
  One configured ingest connector (T-41): a source the installation reads events from, the Access API client trace the events are accepted as, and the size of its pipeline.

      config :relay, Relay.Connectors,
        connectors: [
          [
            name: :orders,
            source: :outbox,
            access_tenant_id: "acc_…",
            access_client_id: "app_…",
            concurrency: 4,
            options: [hostname: "db.example.com", database: "shop", username: "relay_reader",
                      password_file: "/run/secrets/shop_db", table: "public.relay_outbox"]
          ]
        ]

  Sources:

  * `:outbox`, the producer's transactional outbox table in its own PostgreSQL database (`Relay.Connectors.Outbox`); it needs no other component.
  * `:kafka` and `:sqs`, through the Broadway producers of the `broadway_kafka` and `broadway_sqs` packages, whose `options` are passed to them as they are. These packages are not dependencies of Relay (T-7): a release that configures such a source must carry its package, or the node does not start.

  Every message is one structured mode CloudEvent (`application/cloudevents+json`). A configuration error stops the node before any connector starts (INV-46).
  """

  alias Relay.Config.Error
  alias Relay.Connectors.Outbox

  @enforce_keys [:name, :source, :producer, :access_tenant_id, :access_client_id]
  defstruct [
    :name,
    :source,
    :producer,
    :access_tenant_id,
    :access_client_id,
    concurrency: 4,
    hold_ms: 30_000,
    max_wait_ms: 30_000
  ]

  @type source :: :outbox | :kafka | :sqs
  @type t :: %__MODULE__{
          name: atom(),
          source: source() | :test,
          producer: {module(), keyword()},
          access_tenant_id: String.t(),
          access_client_id: String.t(),
          concurrency: pos_integer(),
          hold_ms: pos_integer(),
          max_wait_ms: pos_integer()
        }

  @packages %{
    kafka: {BroadwayKafka.Producer, "broadway_kafka"},
    sqs: {BroadwaySQS.Producer, "broadway_sqs"}
  }
  @keys [:name, :source, :access_tenant_id, :access_client_id, :concurrency, :options]
  @name ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @max_concurrency 64

  # T-41
  # T-7
  # INV-46
  @doc "Reads the configured connectors; raises `Relay.Config.Error` on any invalid entry or a repeated name."
  @spec configured(keyword()) :: [t()]
  def configured(config \\ Application.get_env(:relay, Relay.Connectors, [])) do
    unknown = Keyword.keys(config) -- [:connectors]
    if unknown != [], do: raise(Error, "unknown Relay.Connectors keys: #{inspect(unknown)}")

    connectors = Enum.map(Keyword.get(config, :connectors, []), &parse!/1)
    names = Enum.map(connectors, & &1.name)

    if Enum.uniq(names) != names,
      do: raise(Error, "connector names must be unique: #{inspect(names)}")

    connectors
  end

  # T-41
  @doc "Reads one connector entry; raises `Relay.Config.Error` when it is invalid."
  @spec parse!(term()) :: t()
  def parse!(entry) do
    unless Keyword.keyword?(entry), do: raise(Error, "a connector is a keyword list")

    case Keyword.keys(entry) -- @keys do
      [] -> :ok
      unknown -> raise Error, "unknown connector keys: #{inspect(unknown)}"
    end

    name = name!(entry[:name])
    source = entry[:source]

    %__MODULE__{
      name: name,
      source: source,
      producer: producer!(name, source, Keyword.get(entry, :options, [])),
      access_tenant_id: text!(name, :access_tenant_id, entry[:access_tenant_id]),
      access_client_id: text!(name, :access_client_id, entry[:access_client_id]),
      concurrency: concurrency!(name, Keyword.get(entry, :concurrency, 4))
    }
  end

  @doc "The registered name of a connector's pipeline."
  @spec process_name(t()) :: module()
  def process_name(%__MODULE__{name: name}) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat(Relay.Connectors.Pipeline, Atom.to_string(name))
  end

  defp name!(name) when is_atom(name) and not is_nil(name) do
    if Regex.match?(@name, Atom.to_string(name)),
      do: name,
      else: raise(Error, "a connector name is a lowercase atom of at most 32 characters")
  end

  defp name!(_name), do: raise(Error, "a connector needs a name")

  defp producer!(name, :outbox, options), do: {Outbox, Outbox.options!(name, options)}

  defp producer!(name, source, options) when is_map_key(@packages, source) do
    {module, package} = Map.fetch!(@packages, source)

    cond do
      not Keyword.keyword?(options) ->
        raise Error, "connector #{name}: options are a keyword list"

      not Code.ensure_loaded?(module) ->
        raise Error, "connector #{name}: the #{source} source needs the #{package} package"

      true ->
        {module, options}
    end
  end

  defp producer!(name, source, _options),
    do: raise(Error, "connector #{name}: unknown source #{inspect(source)}")

  defp text!(_name, _key, value) when is_binary(value) and value != "", do: value
  defp text!(name, key, _value), do: raise(Error, "connector #{name}: #{key} is required")

  defp concurrency!(_name, n) when is_integer(n) and n in 1..@max_concurrency, do: n

  defp concurrency!(name, _n),
    do: raise(Error, "connector #{name}: concurrency is 1 to #{@max_concurrency}")
end
