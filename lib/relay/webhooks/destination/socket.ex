defmodule Relay.Webhooks.Destination.Socket do
  @moduledoc """
  The connection of the destinations that do not speak HTTP: Kafka, NATS and RabbitMQ (WH-43). It is the egress boundary for a broker address, with the same policy as `Relay.Webhooks.Egress`: the port is one the installation allows, a metadata host name is refused before anything is resolved, the host is resolved once, every address it has is validated and the connection is refused if any of them is blocked. The connection then goes to a validated address, and the original host name is the TLS server name and the name the certificate is verified against. The name is never resolved a second time. An address a broker advertises for another node is connected through this module as well, so it is validated in the same way.

  Every connection is TLS. `mode: :plain` opens the TCP connection only, for a protocol whose server speaks first; `upgrade/1` then starts TLS on it, and nothing but that greeting is read before the upgrade.

  Bytes are moved by a `Relay.Webhooks.Destination.Socket.Dialer`: `Relay.Webhooks.Destination.Socket.Tls` in production, a scripted one in tests. No policy value lives here; the timeouts come from the caller, and every read is bounded by the deadline the caller holds.
  """

  alias Relay.Clock
  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Socket.Tls
  alias Relay.Webhooks.Egress.Address
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Egress.Resolver
  alias Relay.Webhooks.Egress.Transport

  @enforce_keys [:dialer, :handle, :connection]
  defstruct [:dialer, :handle, :connection]

  @type t :: %__MODULE__{dialer: module(), handle: term(), connection: map()}
  @type endpoint :: {host :: String.t(), :inet.port_number()}
  @type error_class :: :invalid | :blocked | :dns | :connect | :timeout | :tls
  @type error :: %{class: error_class(), reason: String.t(), address: String.t() | nil}
  @type option ::
          {:connect_timeout_ms, pos_integer()}
          | {:dns_timeout_ms, pos_integer()}
          | {:resolver, module()}
          | {:dialer, module()}
          | {:mode, :tls | :plain}
          | {:client_certificate, Transport.client_certificate() | nil}
          | {:ca_certificates, [binary(), ...] | nil}

  @key_types [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
  @host_port ~r/\A([A-Za-z0-9](?:[A-Za-z0-9.-]{0,252}[A-Za-z0-9])?):([0-9]{1,5})\z/

  # WH-43
  @doc "Reads a broker address written as `host:port`."
  @spec endpoint(term()) :: {:ok, endpoint()} | :error
  def endpoint(text) when is_binary(text) do
    case Regex.run(@host_port, text, capture: :all_but_first) do
      [host, port] -> ranged(host, String.to_integer(port))
      nil -> :error
    end
  end

  def endpoint(_text), do: :error

  defp ranged(host, port) when port >= 1 and port <= 65_535, do: {:ok, {host, port}}
  defp ranged(_host, _port), do: :error

  # WH-17
  @doc "The client certificate of a destination: the map the boundary takes, or a PEM certificate chain with the PEM private key the endpoint's credential holds. `nil` when the destination has none."
  @spec client_certificate(term(), term()) ::
          {:ok, Transport.client_certificate() | nil} | :error
  def client_certificate(nil, _credential), do: {:ok, nil}

  def client_certificate(%{certificate: _chain, key: _key} = certificate, _credential),
    do: {:ok, certificate}

  def client_certificate(pem, credential) when is_binary(pem) do
    with true <- Redacted.redacted?(credential),
         [_first | _rest] = chain <- certificates(pem),
         {:ok, key} <- private_key(Redacted.expose(credential)) do
      {:ok, %{certificate: chain, key: Redacted.wrap(key)}}
    else
      _unreadable -> :error
    end
  end

  def client_certificate(_certificate, _credential), do: :error

  defp certificates(pem) do
    for {:Certificate, der, :not_encrypted} <- decoded(pem), do: der
  end

  defp private_key(pem) when is_binary(pem) do
    case decoded(pem) do
      [{type, der, :not_encrypted}] when type in @key_types -> {:ok, {type, der}}
      _other -> :error
    end
  end

  defp private_key(_other), do: :error

  defp decoded(pem) do
    :public_key.pem_decode(pem)
  rescue
    _error -> []
  end

  # WH-43
  # WH-41 (1)
  @doc """
  Connects to a broker address through the egress rules. Options: `:connect_timeout_ms` (required); `:dns_timeout_ms` (the connect timeout when absent), `:resolver`, `:dialer`, `:mode` (`:tls`, or `:plain` before `upgrade/1`), `:client_certificate` and `:ca_certificates`.

  An error carries the class `:invalid`, `:blocked`, `:dns`, `:connect`, `:timeout` or `:tls` and the address that was tried.
  """
  @spec connect(Policy.t(), endpoint(), [option()]) :: {:ok, t()} | {:error, error()}
  def connect(%Policy{} = policy, {host, port}, opts) when is_binary(host) and is_list(opts) do
    with :ok <- port(policy, port),
         {:ok, name, literal} <- host(host),
         :ok <- registrable(policy, name, literal),
         {:ok, addresses} <- addresses(policy, name, literal, opts) do
      dial(addresses, name, port, opts)
    end
  end

  # WH-40 (2)
  defp port(policy, port) do
    if Policy.port_allowed?(policy, port),
      do: :ok,
      else: refusal(:invalid, "port_not_allowed", nil)
  end

  defp host(host) do
    case Address.parse(host) do
      {:ok, ip} -> {:ok, host, Address.canonical(ip)}
      :error -> name(Address.name(host))
    end
  end

  defp name({:ok, name}), do: {:ok, name, nil}
  defp name(:error), do: refusal(:invalid, "invalid_host", nil)

  # WH-54
  defp registrable(policy, host, nil) do
    cond do
      Policy.metadata_host?(policy, host) -> refusal(:blocked, "metadata_host", nil)
      String.contains?(host, ".") or Policy.allowed_host?(policy, host) -> :ok
      true -> refusal(:invalid, "invalid_host", nil)
    end
  end

  defp registrable(policy, host, literal) do
    case Policy.check_address(policy, literal, host) do
      :ok -> :ok
      {:blocked, _range} -> refusal(:blocked, "blocked_address", Address.to_text(literal))
    end
  end

  defp addresses(_policy, _host, literal, _opts) when literal != nil, do: {:ok, [literal]}

  defp addresses(policy, host, nil, opts) do
    :ok = Relay.NetworkGuard.check!(:dns)
    timeout_ms = Keyword.get_lazy(opts, :dns_timeout_ms, fn -> connect_timeout_ms(opts) end)
    resolver = Keyword.get(opts, :resolver, Resolver.Inet)

    case resolver.resolve(host, timeout_ms) do
      {:ok, resolved} -> validated(policy, host, resolved)
      {:error, reason} -> refusal(:dns, Atom.to_string(reason), nil)
    end
  end

  # WH-41 (1)
  # WH-41 (2)
  defp validated(policy, host, resolved) do
    addresses = resolved |> Enum.map(&Address.canonical/1) |> Enum.uniq()
    blocked = Enum.find_value(addresses, &blocked(policy, &1, host))

    cond do
      blocked != nil -> {:error, blocked}
      addresses == [] -> refusal(:dns, "no_address", nil)
      true -> {:ok, Enum.sort_by(addresses, &tuple_size/1)}
    end
  end

  defp blocked(policy, ip, host) do
    case Policy.check_address(policy, ip, host) do
      :ok -> nil
      {:blocked, range} -> %{class: :blocked, reason: range, address: Address.to_text(ip)}
    end
  end

  defp dial([ip | rest], host, port, opts) do
    :ok = Relay.NetworkGuard.check!(:http)
    dialer = Keyword.get(opts, :dialer, Tls)
    connection = connection(ip, host, port, opts)

    case dialer.connect(connection) do
      {:ok, handle} -> {:ok, %__MODULE__{dialer: dialer, handle: handle, connection: connection}}
      {:error, %{class: :connect}} when rest != [] -> dial(rest, host, port, opts)
      {:error, error} -> {:error, Map.put(error, :address, Address.to_text(ip))}
    end
  end

  defp connection(ip, host, port, opts) do
    %{
      address: ip,
      host: host,
      port: port,
      mode: Keyword.get(opts, :mode, :tls),
      connect_timeout_ms: connect_timeout_ms(opts),
      client_certificate: Keyword.get(opts, :client_certificate),
      ca_certificates: Keyword.get(opts, :ca_certificates)
    }
  end

  defp connect_timeout_ms(opts), do: Keyword.fetch!(opts, :connect_timeout_ms)

  @doc "Starts TLS on a connection opened with `mode: :plain`, with the host name the connection was validated for."
  @spec upgrade(t()) :: {:ok, t()} | {:error, error()}
  def upgrade(%__MODULE__{dialer: dialer, handle: handle, connection: connection} = socket) do
    case dialer.upgrade(handle, connection) do
      {:ok, handle} -> {:ok, %{socket | handle: handle}}
      {:error, error} -> {:error, located(error, socket)}
    end
  end

  @doc "The address the connection was made to, as text."
  @spec address(t()) :: String.t()
  def address(%__MODULE__{connection: %{address: ip}}), do: Address.to_text(ip)

  # WH-24
  @doc "The deadline of an exchange that may take `total_timeout_ms` from now, on the monotonic clock."
  @spec deadline(pos_integer()) :: integer()
  def deadline(total_timeout_ms) when is_integer(total_timeout_ms) and total_timeout_ms > 0,
    do: Clock.monotonic_ms() + total_timeout_ms

  @doc "Writes to the connection."
  @spec write(t(), iodata()) :: :ok | {:error, error()}
  def write(%__MODULE__{dialer: dialer, handle: handle} = socket, data) do
    case dialer.write(handle, data) do
      :ok -> :ok
      {:error, error} -> {:error, located(error, socket)}
    end
  end

  # WH-24
  @doc "Reads exactly `length` bytes, or what has arrived when `length` is 0, before `deadline`."
  @spec read(t(), non_neg_integer(), integer()) :: {:ok, binary()} | {:error, error()}
  def read(%__MODULE__{dialer: dialer, handle: handle} = socket, length, deadline)
      when is_integer(length) and length >= 0 and is_integer(deadline) do
    remaining = deadline - Clock.monotonic_ms()

    if remaining > 0 do
      handle |> dialer.read(length, remaining) |> read_result(socket)
    else
      {:error, located(%{class: :timeout, reason: "total_timeout"}, socket)}
    end
  end

  defp read_result({:ok, data}, _socket), do: {:ok, data}
  defp read_result({:error, error}, socket), do: {:error, located(error, socket)}

  @doc "Closes the connection."
  @spec close(t()) :: :ok
  def close(%__MODULE__{dialer: dialer, handle: handle}), do: dialer.close(handle)

  defp located(error, socket), do: Map.put(error, :address, address(socket))

  defp refusal(class, reason, address),
    do: {:error, %{class: class, reason: reason, address: address}}
end
