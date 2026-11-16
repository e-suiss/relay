defmodule Relay.Webhooks.Egress do
  @moduledoc """
  The only way an outbound delivery opens a connection (WH-40 … WH-44, WH-54). It applies to every outbound path alike: HTTPS endpoints, the workflow `webhook` step, agent push, broker addresses and OAuth2 token endpoints (WH-43).

  `validate_url/2` holds the registration rules: `https` only, in the test plane too; port 443 or a port the installation allows; no user information; a syntactically plain host; a metadata host name refused before anything is resolved. `dns_findings/3` is the early DNS check of a registration; it is feedback only and decides nothing.

  `request/3` is the boundary itself. It validates the URL again, resolves the host once, validates every address the name has and refuses the request if any of them is blocked, then connects to a validated address with the original host name as SNI, as `Host` and as the name the certificate is verified against. The name is never resolved a second time, so DNS rebinding cannot move the connection. A redirect is never followed, the time is bounded by the caller's connect and total timeouts, at most `max_response_bytes` of the response body are read and the address that was used is reported back for the attempt log. No policy value lives here: timeouts, the response cap, the ports and the allow-list come from the caller.

  DNS and HTTP are reached through `Relay.Webhooks.Egress.Resolver` and `Relay.Webhooks.Egress.Transport`, and `Relay.NetworkGuard` is checked before each of them, so a request is never made inside a database transaction.
  """

  alias Relay.Webhooks.Egress.Address
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Egress.Resolver
  alias Relay.Webhooks.Egress.Transport

  @type target :: %{
          host: String.t(),
          port: :inet.port_number(),
          path: String.t(),
          literal: Address.ip() | nil
        }
  @type url_error ::
          :invalid_url
          | :scheme_not_https
          | :userinfo_not_allowed
          | :invalid_host
          | :port_not_allowed
          | :metadata_host
          | :blocked_address
  @type finding ::
          {:blocked_address, address :: String.t(), range :: String.t()}
          | {:unresolved, Resolver.error()}
  @type request :: %{
          method: String.t(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata()
        }
  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary(),
          truncated: boolean(),
          address: String.t(),
          duration_ms: non_neg_integer()
        }
  @type error_class :: :invalid | :blocked | :dns | :connect | :timeout | :tls | :protocol
  @type error :: %{
          class: error_class(),
          reason: String.t(),
          address: String.t() | nil,
          duration_ms: non_neg_integer()
        }
  @type option ::
          {:connect_timeout_ms, pos_integer()}
          | {:total_timeout_ms, pos_integer()}
          | {:max_response_bytes, non_neg_integer()}
          | {:dns_timeout_ms, pos_integer()}
          | {:resolver, module()}
          | {:transport, module()}
          | {:client_certificate, Transport.client_certificate() | nil}
          | {:ca_certificates, [binary(), ...] | nil}
          | {:proxy, Transport.proxy() | nil}

  @plain ~r/\A[\x21-\x7E]+\z/
  @header_name ~r/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/
  @header_value ~r/\A[\x20-\x7E\t]*\z/
  @fixed ~w(host content-length transfer-encoding connection)
  @refused [:blocked_address, :metadata_host]

  # WH-40
  # WH-54
  @doc "Applies the registration rules to a URL and returns where a request to it would go."
  @spec validate_url(Policy.t(), term()) :: {:ok, target()} | {:error, url_error()}
  def validate_url(%Policy{} = policy, url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- scheme(uri),
         :ok <- userinfo(uri),
         {:ok, host, literal} <- host(uri.host),
         :ok <- port(policy, uri.port),
         :ok <- registrable(policy, host, literal) do
      {:ok, %{host: host, port: uri.port, path: path(uri), literal: literal}}
    end
  end

  def validate_url(%Policy{}, _url), do: {:error, :invalid_url}

  defp parse(url) do
    if Regex.match?(@plain, url) and not String.contains?(url, "\\"),
      do: parsed(URI.new(url)),
      else: {:error, :invalid_url}
  end

  defp parsed({:ok, uri}), do: {:ok, uri}
  defp parsed({:error, _part}), do: {:error, :invalid_url}

  # WH-40 (1)
  defp scheme(%URI{scheme: "https"}), do: :ok
  defp scheme(%URI{}), do: {:error, :scheme_not_https}

  # WH-40 (3)
  defp userinfo(%URI{userinfo: nil}), do: :ok
  defp userinfo(%URI{}), do: {:error, :userinfo_not_allowed}

  defp host(host) when is_binary(host) and host != "" do
    case Address.parse(host) do
      {:ok, ip} -> {:ok, host, Address.canonical(ip)}
      :error -> name(Address.name(host))
    end
  end

  defp host(_host), do: {:error, :invalid_host}

  defp name({:ok, name}), do: {:ok, name, nil}
  defp name(:error), do: {:error, :invalid_host}

  # WH-40 (2)
  defp port(policy, port) do
    if Policy.port_allowed?(policy, port), do: :ok, else: {:error, :port_not_allowed}
  end

  # WH-54
  defp registrable(policy, host, nil) do
    cond do
      Policy.metadata_host?(policy, host) -> {:error, :metadata_host}
      String.contains?(host, ".") or Policy.allowed_host?(policy, host) -> :ok
      true -> {:error, :invalid_host}
    end
  end

  defp registrable(policy, host, literal) do
    case Policy.check_address(policy, literal, host) do
      :ok -> :ok
      {:blocked, _range} -> {:error, :blocked_address}
    end
  end

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query == nil, do: path, else: path <> "?" <> query
  end

  # WH-40 (4)
  @doc """
  The early DNS check of a registration: resolves the host of a valid URL and reports each address that the boundary would refuse, or that the name does not resolve. The result is feedback for the person registering the endpoint, never a security decision. Options: `:dns_timeout_ms` (required) and `:resolver`.
  """
  @spec dns_findings(Policy.t(), term(), keyword()) :: {:ok, [finding()]} | {:error, url_error()}
  def dns_findings(%Policy{} = policy, url, opts) when is_list(opts) do
    with {:ok, target} <- validate_url(policy, url), do: {:ok, findings(policy, target, opts)}
  end

  defp findings(_policy, %{literal: literal}, _opts) when literal != nil, do: []

  defp findings(policy, %{host: host}, opts) do
    case resolve(host, Keyword.fetch!(opts, :dns_timeout_ms), opts) do
      {:ok, resolved} -> Enum.flat_map(resolved, &finding(policy, &1, host))
      {:error, reason} -> [{:unresolved, reason}]
    end
  end

  defp finding(policy, ip, host) do
    case Policy.check_address(policy, ip, host) do
      :ok -> []
      {:blocked, range} -> [{:blocked_address, Address.to_text(Address.canonical(ip)), range}]
    end
  end

  # WH-41 (1)
  # WH-42 (3)
  # WH-43
  # WH-44 (3)
  @doc """
  Sends one request through the boundary. Options: `:connect_timeout_ms`, `:total_timeout_ms` and `:max_response_bytes` (required); `:dns_timeout_ms` (the connect timeout when absent), `:resolver`, `:transport`, `:client_certificate` (mTLS), `:ca_certificates` and `:proxy` (an egress proxy).

  The answer carries the address that was used and the duration; so does an error, whose class is `:invalid`, `:blocked`, `:dns`, `:connect`, `:timeout`, `:tls` or `:protocol`.
  """
  @spec request(Policy.t(), request(), [option()]) :: {:ok, response()} | {:error, error()}
  def request(%Policy{} = policy, %{url: url, headers: headers} = request, opts)
      when is_list(opts) do
    started = Relay.Clock.monotonic_ms()

    result =
      with :ok <- sendable(headers),
           {:ok, target} <- target(policy, url),
           {:ok, addresses} <- addresses(policy, target, opts) do
        attempt(addresses, target, request, opts, started)
      end

    timed(result, max(Relay.Clock.monotonic_ms() - started, 0))
  end

  defp timed({:ok, response}, ms), do: {:ok, Map.put(response, :duration_ms, ms)}
  defp timed({:error, error}, ms), do: {:error, Map.put(error, :duration_ms, ms)}

  defp sendable(headers) when is_list(headers) do
    if Enum.all?(headers, &header?/1), do: :ok, else: refusal(:invalid, "invalid_header", nil)
  end

  defp sendable(_headers), do: refusal(:invalid, "invalid_header", nil)

  defp header?({name, value}) when is_binary(name) and is_binary(value),
    do: Regex.match?(@header_name, name) and Regex.match?(@header_value, value)

  defp header?(_header), do: false

  defp target(policy, url) do
    case validate_url(policy, url) do
      {:ok, target} -> {:ok, target}
      {:error, reason} when reason in @refused -> refusal(:blocked, Atom.to_string(reason), nil)
      {:error, reason} -> refusal(:invalid, Atom.to_string(reason), nil)
    end
  end

  defp addresses(_policy, %{literal: literal}, _opts) when literal != nil, do: {:ok, [literal]}

  defp addresses(policy, %{host: host}, opts) do
    timeout_ms = Keyword.get_lazy(opts, :dns_timeout_ms, fn -> connect_timeout_ms(opts) end)

    case resolve(host, timeout_ms, opts) do
      {:ok, resolved} -> validated(policy, host, resolved)
      {:error, reason} -> refusal(:dns, Atom.to_string(reason), nil)
    end
  end

  defp resolve(host, timeout_ms, opts) do
    :ok = Relay.NetworkGuard.check!(:dns)
    resolver = Keyword.get(opts, :resolver, Resolver.Inet)
    resolver.resolve(host, timeout_ms)
  end

  # WH-41 (1)
  # WH-41 (2)
  defp validated(policy, host, resolved) do
    addresses = resolved |> Enum.map(&Address.canonical/1) |> Enum.uniq()

    case Enum.find(addresses, &(Policy.check_address(policy, &1, host) != :ok)) do
      nil when addresses == [] -> refusal(:dns, "no_address", nil)
      nil -> {:ok, Enum.sort_by(addresses, &tuple_size/1)}
      ip -> refusal(:blocked, blocked_range(policy, ip, host), Address.to_text(ip))
    end
  end

  defp blocked_range(policy, ip, host) do
    case Policy.check_address(policy, ip, host) do
      {:blocked, range} -> range
      :ok -> "blocked"
    end
  end

  defp attempt([ip | rest], target, request, opts, start) do
    :ok = Relay.NetworkGuard.check!(:http)
    transport = Keyword.get(opts, :transport, Transport.Pinned)
    address = Address.to_text(ip)

    case transport.request(connection(ip, target, opts, start), wire(request, target)) do
      {:ok, response} -> {:ok, Map.put(response, :address, address)}
      {:error, %{class: :connect}} when rest != [] -> attempt(rest, target, request, opts, start)
      {:error, error} -> {:error, Map.put(error, :address, address)}
    end
  end

  # WH-24
  defp connection(ip, target, opts, started) do
    spent = Relay.Clock.monotonic_ms() - started

    %{
      address: ip,
      host: target.host,
      port: target.port,
      connect_timeout_ms: connect_timeout_ms(opts),
      total_timeout_ms: max(Keyword.fetch!(opts, :total_timeout_ms) - spent, 1),
      max_response_bytes: Keyword.fetch!(opts, :max_response_bytes),
      client_certificate: Keyword.get(opts, :client_certificate),
      ca_certificates: Keyword.get(opts, :ca_certificates),
      proxy: Keyword.get(opts, :proxy)
    }
  end

  defp connect_timeout_ms(opts), do: Keyword.fetch!(opts, :connect_timeout_ms)

  defp wire(%{method: method, headers: headers, body: body}, target) do
    kept = Enum.reject(headers, fn {name, _value} -> String.downcase(name, :ascii) in @fixed end)
    %{method: method, path: target.path, headers: kept ++ [{"connection", "close"}], body: body}
  end

  defp refusal(class, reason, address),
    do: {:error, %{class: class, reason: reason, address: address}}
end
