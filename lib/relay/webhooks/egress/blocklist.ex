defmodule Relay.Webhooks.Egress.Blocklist do
  @moduledoc """
  The blocked address ranges and the cloud metadata addresses and host names of the egress boundary (WH-41 (3), WH-54). The list is data: `priv/webhooks/blocked_ranges.json` and `priv/webhooks/metadata.json` are read when the module is compiled, and an installation may only add to them with `extend/2`.

  A range marked `"allow_listable": false` in the data (loopback) and every metadata address can never be exempted by an installation allow-list (WH-44 (3)).
  """

  alias Relay.Webhooks.Egress.Address

  @ranges_path Path.expand("../../../../priv/webhooks/blocked_ranges.json", __DIR__)
  @metadata_path Path.expand("../../../../priv/webhooks/metadata.json", __DIR__)
  @external_resource @ranges_path
  @external_resource @metadata_path

  @metadata_name "cloud_metadata"

  decoded = @ranges_path |> File.read!() |> Jason.decode!() |> Map.fetch!("ranges")

  ranges =
    for %{"cidr" => text, "name" => name} = range <- decoded do
      {:ok, cidr} = Address.parse_cidr(text)
      %{cidr: cidr, name: name, allow_listable: Map.get(range, "allow_listable", true)}
    end

  metadata = @metadata_path |> File.read!() |> Jason.decode!()

  addresses =
    for text <- Map.fetch!(metadata, "addresses") do
      {:ok, ip} = Address.parse(text)
      ip
    end

  @default %{
    ranges: ranges,
    metadata_addresses: addresses,
    metadata_hosts: Map.fetch!(metadata, "hosts")
  }

  defstruct ranges: [], metadata_addresses: [], metadata_hosts: []

  @type range :: %{cidr: Address.cidr(), name: String.t(), allow_listable: boolean()}
  @type t :: %__MODULE__{
          ranges: [range()],
          metadata_addresses: [Address.ip()],
          metadata_hosts: [String.t()]
        }
  @type additions :: %{
          optional(:ranges) => [String.t()],
          optional(:metadata_addresses) => [String.t()],
          optional(:metadata_hosts) => [String.t()]
        }

  # WH-41 (3)
  @doc "The list shipped with the release."
  @spec default() :: t()
  def default, do: struct!(__MODULE__, @default)

  # WH-41 (3)
  @doc "Adds installation ranges, metadata addresses and metadata host names. Nothing is ever removed."
  @spec extend(t(), additions()) :: {:ok, t()} | {:error, {:invalid_entry, String.t()}}
  def extend(%__MODULE__{} = blocklist, additions) when is_map(additions) do
    with {:ok, ranges} <- each(Map.get(additions, :ranges, []), &added_range/1),
         {:ok, addresses} <- each(Map.get(additions, :metadata_addresses, []), &Address.parse/1),
         {:ok, hosts} <- each(Map.get(additions, :metadata_hosts, []), &Address.name/1) do
      ranges = blocklist.ranges ++ ranges
      addresses = Enum.uniq(blocklist.metadata_addresses ++ addresses)
      hosts = Enum.uniq(blocklist.metadata_hosts ++ hosts)
      {:ok, %__MODULE__{ranges: ranges, metadata_addresses: addresses, metadata_hosts: hosts}}
    end
  end

  defp added_range(text) do
    case Address.parse_cidr(text) do
      {:ok, cidr} -> {:ok, %{cidr: cidr, name: "installation", allow_listable: true}}
      :error -> :error
    end
  end

  defp each(entries, parser) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case parsed(entry, parser) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :error -> {:halt, {:error, {:invalid_entry, inspect(entry)}}}
      end
    end)
  end

  defp parsed(entry, parser) when is_binary(entry), do: parser.(entry)
  defp parsed(_entry, _parser), do: :error

  # WH-41 (3)
  @doc "The blocked range or metadata entry an address falls in, or `nil`. A metadata address and a range that can never be allow-listed win over a range that can."
  @spec match(t(), Address.ip()) :: %{name: String.t(), allow_listable: boolean()} | nil
  def match(%__MODULE__{} = blocklist, ip) do
    if ip in blocklist.metadata_addresses do
      %{name: @metadata_name, allow_listable: false}
    else
      blocklist.ranges
      |> Enum.filter(&Address.member?(ip, &1.cidr))
      |> Enum.min_by(& &1.allow_listable, fn -> nil end)
      |> entry()
    end
  end

  defp entry(nil), do: nil
  defp entry(range), do: Map.take(range, [:name, :allow_listable])

  # WH-54
  @doc "Whether a normalised host name is a metadata host name or lies under one."
  @spec metadata_host?(t(), String.t()) :: boolean()
  def metadata_host?(%__MODULE__{metadata_hosts: hosts}, host) when is_binary(host),
    do: Enum.any?(hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

  # WH-44 (3)
  @doc "Whether a range touches an address that can never be allow-listed: loopback or a metadata address."
  @spec never_allowed?(t(), Address.cidr()) :: boolean()
  def never_allowed?(%__MODULE__{} = blocklist, cidr) do
    Enum.any?(blocklist.metadata_addresses, &Address.member?(&1, cidr)) or
      Enum.any?(blocklist.ranges, &(not &1.allow_listable and Address.overlap?(&1.cidr, cidr)))
  end
end
