defmodule Relay.Webhooks.Egress.Policy do
  @moduledoc """
  The egress policy of an installation: the blocklist, the ports allowed besides 443 (WH-40 (2)) and the self-host allow-list (WH-44). It is built once from installation configuration with `new/1`; a tenant can neither open nor widen it.

  The allow-list holds CIDR ranges, single addresses and host names. It only exempts an address from the blocked range check; every address is still validated when the connection is made. An entry that touches loopback or a cloud metadata address, or names a metadata host, is refused, and a SaaS installation has no allow-list at all.
  """

  alias Relay.Webhooks.Egress.Address
  alias Relay.Webhooks.Egress.Blocklist

  @enforce_keys [:blocklist]
  defstruct [:blocklist, ports: [], allow_ranges: [], allow_hosts: []]

  @type t :: %__MODULE__{
          blocklist: Blocklist.t(),
          ports: [:inet.port_number()],
          allow_ranges: [Address.cidr()],
          allow_hosts: [String.t()]
        }
  @type option ::
          {:deployment, :saas | :self_hosted}
          | {:blocklist, Blocklist.t()}
          | {:extra_ports, [:inet.port_number()]}
          | {:allow_list, [String.t()]}
  @type error ::
          :invalid_port
          | :allow_list_not_available
          | {:invalid_entry, String.t()}
          | {:not_allow_listable, String.t()}

  # WH-40 (2)
  # WH-44
  @doc "Builds the policy. `:deployment` is required; `:blocklist` defaults to the shipped list, `:extra_ports` and `:allow_list` to nothing."
  @spec new([option()]) :: {:ok, t()} | {:error, error()}
  def new(opts) when is_list(opts) do
    blocklist = Keyword.get_lazy(opts, :blocklist, &Blocklist.default/0)
    entries = Keyword.get(opts, :allow_list, [])

    with {:ok, ports} <- ports(Keyword.get(opts, :extra_ports, [])),
         :ok <- available(Keyword.fetch!(opts, :deployment), entries),
         {:ok, {ranges, hosts}} <- allow_list(blocklist, entries) do
      policy = %__MODULE__{blocklist: blocklist, ports: ports, allow_ranges: ranges}
      {:ok, %{policy | allow_hosts: hosts}}
    end
  end

  defp ports(ports) when is_list(ports) do
    if Enum.all?(ports, &(is_integer(&1) and &1 >= 1 and &1 <= 65_535)),
      do: {:ok, Enum.uniq(ports)},
      else: {:error, :invalid_port}
  end

  defp ports(_ports), do: {:error, :invalid_port}

  # WH-44 (4)
  defp available(:self_hosted, _entries), do: :ok
  defp available(:saas, []), do: :ok
  defp available(:saas, _entries), do: {:error, :allow_list_not_available}

  defp allow_list(blocklist, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, {[], []}}, fn entry, {:ok, {ranges, hosts}} ->
      case entry(blocklist, entry) do
        {:range, cidr} -> {:cont, {:ok, {ranges ++ [cidr], hosts}}}
        {:host, host} -> {:cont, {:ok, {ranges, hosts ++ [host]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # WH-44 (3)
  defp entry(blocklist, text) when is_binary(text) do
    case Address.parse_cidr(text) do
      {:ok, cidr} -> range(blocklist, cidr, text)
      :error -> host(blocklist, Address.name(text), text)
    end
  end

  defp entry(_blocklist, other), do: {:error, {:invalid_entry, inspect(other)}}

  defp range(blocklist, cidr, text) do
    if Blocklist.never_allowed?(blocklist, cidr),
      do: {:error, {:not_allow_listable, text}},
      else: {:range, cidr}
  end

  defp host(_blocklist, :error, text), do: {:error, {:invalid_entry, text}}

  defp host(blocklist, {:ok, host}, text) do
    if Blocklist.metadata_host?(blocklist, host),
      do: {:error, {:not_allow_listable, text}},
      else: {:host, host}
  end

  # WH-40 (2)
  @doc "Whether a port may be used: 443, or a port the installation added."
  @spec port_allowed?(t(), term()) :: boolean()
  def port_allowed?(%__MODULE__{ports: ports}, port), do: port == 443 or port in ports

  # WH-54
  @doc "Whether a normalised host name is refused before any resolution."
  @spec metadata_host?(t(), String.t()) :: boolean()
  def metadata_host?(%__MODULE__{blocklist: blocklist}, host),
    do: Blocklist.metadata_host?(blocklist, host)

  @doc "Whether the installation allow-list names the host."
  @spec allowed_host?(t(), String.t()) :: boolean()
  def allowed_host?(%__MODULE__{allow_hosts: hosts}, host), do: host in hosts

  # WH-41
  # WH-44 (3)
  @doc """
  Validates one address for a connection to `host`. An IPv4-mapped address is checked as its IPv4 form, and an address that carries an IPv4 address is checked together with it. The result is `:ok` or `{:blocked, name}` with the name of the range that refused it.
  """
  @spec check_address(t(), Address.ip(), String.t()) :: :ok | {:blocked, String.t()}
  def check_address(%__MODULE__{} = policy, ip, host) when is_binary(host) do
    ip = Address.canonical(ip)
    Enum.find_value([ip | Address.embedded(ip)], :ok, &verdict(policy, &1, host))
  end

  defp verdict(policy, ip, host) do
    case Blocklist.match(policy.blocklist, ip) do
      nil -> nil
      %{allow_listable: true, name: name} -> exempt(policy, ip, host, name)
      %{name: name} -> {:blocked, name}
    end
  end

  defp exempt(policy, ip, host, name) do
    if host in policy.allow_hosts or Enum.any?(policy.allow_ranges, &Address.member?(ip, &1)),
      do: nil,
      else: {:blocked, name}
  end
end
