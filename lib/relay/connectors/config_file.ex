defmodule Relay.Connectors.ConfigFile do
  @moduledoc """
  The ingest connectors of a production node, read from the JSON file that `RELAY_CONNECTORS_FILE` names (T-96). `config/runtime.exs` reads the file once at boot; the file is checked strictly with the connector rules of `Relay.Connectors.Connector`, and any error stops the node before it starts. Without the variable no connector runs.

      {
        "connectors": [
          {
            "name": "orders",
            "source": "outbox",
            "access_tenant_id": "acc_…",
            "access_client_id": "app_…",
            "concurrency": 4,
            "options": {
              "hostname": "db.example.com",
              "database": "shop",
              "username": "relay_reader",
              "password_file": "/run/secrets/shop_db",
              "table": "public.relay_outbox",
              "ssl": {"cacertfile": "/run/secrets/shop_db_ca.pem"}
            }
          }
        ]
      }

  A password is never written in the file: the outbox source reads it from `password_file` at every connect (`Relay.Config.SecretFiles.configure_path/2`). `ssl` is `false`, `true`, or an object with `cacertfile` and `server_name_indication`, which verifies the peer. The options of a `kafka` or `sqs` source are passed to its producer with their keys as atoms that its package defines; the package must be part of the release (T-95).
  """

  alias Relay.Config.Error
  alias Relay.Connectors.Connector

  @variable "RELAY_CONNECTORS_FILE"
  @entry_keys %{
    "name" => :name,
    "source" => :source,
    "access_tenant_id" => :access_tenant_id,
    "access_client_id" => :access_client_id,
    "concurrency" => :concurrency,
    "options" => :options
  }
  @sources %{"outbox" => :outbox, "kafka" => :kafka, "sqs" => :sqs}
  @outbox_keys Map.new(
                 ~w(hostname port database username password_file ssl table poll_ms batch_size
                    lease_s)a,
                 &{Atom.to_string(&1), &1}
               )
  @ssl_keys %{"cacertfile" => :cacertfile, "server_name_indication" => :server_name_indication}
  @name ~r/\A[a-z][a-z0-9_]{0,31}\z/

  # T-96
  # INV-46
  @doc "The connector entries of the file at `path`; `nil` (the variable is not set) is no connector. Raises `Relay.Config.Error` when the file cannot be read, is not JSON or holds an invalid connector."
  @spec read!(String.t() | nil) :: [keyword()]
  def read!(nil), do: []
  def read!(""), do: raise(Error, "#{@variable} is empty; leave it unset for no connector")

  # sobelow_skip ["Traversal.FileModule"]
  def read!(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse!(content)
      {:error, reason} -> raise Error, "cannot read #{@variable}: #{:file.format_error(reason)}"
    end
  end

  # T-96
  # INV-46
  @doc "The connector entries of a JSON document, checked with `Relay.Connectors.Connector.configured/1`; raises `Relay.Config.Error` on any error."
  @spec parse!(String.t()) :: [keyword()]
  def parse!(content) when is_binary(content) do
    entries =
      case Jason.decode(content) do
        {:ok, %{"connectors" => list} = doc} when is_list(list) and map_size(doc) == 1 ->
          Enum.map(list, &entry!/1)

        {:ok, _other} ->
          fail!("the file is an object with one key, connectors, a list")

        {:error, _reason} ->
          fail!("the file is not valid JSON")
      end

    Connector.configured(connectors: entries)
    entries
  end

  defp entry!(entry) when is_map(entry) do
    pairs = Enum.map(entry, &entry_pair!/1)

    case Keyword.fetch(pairs, :options) do
      {:ok, options} -> Keyword.put(pairs, :options, options!(pairs[:source], options))
      :error -> pairs
    end
  end

  defp entry!(_entry), do: fail!("a connector is an object")

  defp entry_pair!({key, value}) do
    case Map.fetch(@entry_keys, key) do
      {:ok, :name} -> {:name, name!(value)}
      {:ok, :source} -> {:source, source!(value)}
      {:ok, atom} -> {atom, value}
      :error -> fail!("unknown connector key #{inspect(key)}")
    end
  end

  defp name!(name) when is_binary(name) do
    if not Regex.match?(@name, name),
      do: fail!("a connector name is lowercase, at most 32 characters")

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    String.to_atom(name)
  end

  defp name!(_name), do: fail!("a connector name is a string")

  defp source!(source) do
    case Map.fetch(@sources, source) do
      {:ok, atom} -> atom
      :error -> fail!("unknown connector source #{inspect(source)}")
    end
  end

  defp options!(:outbox, %{} = options) do
    for {key, value} <- options do
      case Map.fetch(@outbox_keys, key) do
        {:ok, :ssl} -> {:ssl, ssl!(value)}
        {:ok, atom} -> {atom, value}
        :error when key == "password" -> fail!("a password comes from password_file")
        :error -> fail!("unknown outbox option #{inspect(key)}")
      end
    end
  end

  defp options!(source, %{} = options) when source in [:kafka, :sqs],
    do: producer_options!(options)

  defp options!(nil, _options), do: fail!("a connector needs a source")
  defp options!(_source, _options), do: fail!("connector options are an object")

  defp ssl!(ssl) when is_boolean(ssl), do: ssl

  defp ssl!(%{} = ssl) when map_size(ssl) > 0 do
    options =
      for {key, value} <- ssl do
        case {Map.fetch(@ssl_keys, key), value} do
          {{:ok, atom}, value} when is_binary(value) and value != "" ->
            {atom, String.to_charlist(value)}

          _other ->
            fail!("ssl takes cacertfile and server_name_indication as strings")
        end
      end

    [{:verify, :verify_peer} | options]
  end

  defp ssl!(_ssl), do: fail!("ssl is a boolean or an object")

  defp producer_options!(options) when is_map(options) do
    for {key, value} <- options, do: {existing_atom!(key), producer_options!(value)}
  end

  defp producer_options!(list) when is_list(list), do: Enum.map(list, &producer_options!/1)
  defp producer_options!(value), do: value

  defp existing_atom!(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> fail!("unknown producer option #{inspect(key)}")
  end

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: raise(Error, "#{@variable}: #{message}")
end
