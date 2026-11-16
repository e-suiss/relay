defmodule Relay.Webhooks.Destination.SocketTest.Resolver do
  @behaviour Relay.Webhooks.Egress.Resolver

  @impl Relay.Webhooks.Egress.Resolver
  def resolve(host, _timeout_ms) do
    send(self(), {:resolved, host})
    Process.get({:dns, host}, {:ok, [{203, 0, 114, 10}]})
  end
end

defmodule Relay.Webhooks.Destination.SocketTest.Loopback do
  @behaviour Relay.Webhooks.Destination.Socket.Dialer

  alias Relay.Webhooks.Destination.Socket.Tls

  @impl Relay.Webhooks.Destination.Socket.Dialer
  def connect(connection) do
    send(self(), {:dialed, connection})
    Tls.connect(%{connection | address: {127, 0, 0, 1}, port: Process.get(:loopback_port)})
  end

  @impl Relay.Webhooks.Destination.Socket.Dialer
  defdelegate upgrade(handle, connection), to: Tls

  @impl Relay.Webhooks.Destination.Socket.Dialer
  defdelegate write(handle, data), to: Tls

  @impl Relay.Webhooks.Destination.Socket.Dialer
  defdelegate read(handle, length, timeout_ms), to: Tls

  @impl Relay.Webhooks.Destination.Socket.Dialer
  defdelegate close(handle), to: Tls
end

defmodule Relay.Webhooks.Destination.SocketTest do
  use ExUnit.Case, async: true

  alias Relay.Redacted
  alias Relay.Webhooks.Destination.Socket
  alias Relay.Webhooks.Destination.SocketTest.Loopback
  alias Relay.Webhooks.Destination.SocketTest.Resolver
  alias Relay.Webhooks.Egress.Policy
  alias RelayTest.ScriptedSocket

  @host "broker.example.test"
  @listen [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  setup_all do
    %{chains: chains(@host)}
  end

  setup do
    {:ok, policy} = Policy.new(deployment: :saas, extra_ports: [9093])
    options = [connect_timeout_ms: 5_000, resolver: Resolver, dialer: ScriptedSocket]
    %{policy: policy, options: options}
  end

  defp chains(host) do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}
    key = {:rsa, 2048, 65_537}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: key], intermediates: [], peer: [key: key, extensions: [san]]},
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    %{server: server, client: client}
  end

  defp echo(:open, state), do: {"", state}
  defp echo(:upgrade, state), do: {"", state}
  defp echo({:data, data}, state), do: {"echo:" <> data, state}

  defp serve(tls, greeting) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, @listen)
    {:ok, port} = :inet.port(listen)
    {:ok, _pid} = Task.start_link(fn -> accept(listen, tls, greeting, test) end)
    Process.put(:loopback_port, port)
    port
  end

  defp accept(listen, tls, greeting, test) do
    {:ok, tcp} = :gen_tcp.accept(listen, 10_000)
    :ok = :gen_tcp.send(tcp, greeting)

    case :ssl.handshake(tcp, tls, 10_000) do
      {:ok, socket} -> answer(socket, test)
      {:error, _reason} -> send(test, :handshake_failed)
    end
  end

  defp answer(socket, test) do
    {:ok, information} = :ssl.connection_information(socket, [:sni_hostname])
    {:ok, data} = :ssl.recv(socket, 0, 5_000)
    send(test, {:served, to_string(information[:sni_hostname]), data, peer(socket)})
    :ok = :ssl.send(socket, "echo:" <> data)
    :ssl.close(socket)
  end

  defp peer(socket) do
    case :ssl.peercert(socket) do
      {:ok, certificate} -> certificate
      {:error, _reason} -> nil
    end
  end

  defp loopback(ctx, extra) do
    base = [dialer: Loopback, ca_certificates: ctx.chains.client[:cacerts]]
    Keyword.merge(ctx.options, Keyword.merge(base, extra))
  end

  describe "WH-43 broker addresses" do
    test "WH-43: a broker address is host and port" do
      assert Socket.endpoint("broker-1.example.com:9093") == {:ok, {"broker-1.example.com", 9093}}
      assert Socket.endpoint("203.0.114.10:443") == {:ok, {"203.0.114.10", 443}}

      for text <- ["broker.example.com", "broker.example.com:0", "broker.example.com:70000"] do
        assert Socket.endpoint(text) == :error
      end

      for text <- ["user@broker.example.com:9093", "broker.example.com:9093/x", ":9093", nil] do
        assert Socket.endpoint(text) == :error
      end
    end

    test "WH-43: the host is resolved once and the validated address is dialed", ctx do
      ScriptedSocket.serve("broker.example.com", &echo/2)

      assert {:ok, socket} = Socket.connect(ctx.policy, {"Broker.Example.com", 9093}, ctx.options)
      assert Socket.address(socket) == "203.0.114.10"

      assert_received {:resolved, "broker.example.com"}
      refute_received {:resolved, _host}
      assert_received {:dialed, connection}
      assert %{address: {203, 0, 114, 10}, host: "broker.example.com", port: 9093} = connection
      assert %{mode: :tls, connect_timeout_ms: 5_000, client_certificate: nil} = connection

      deadline = Socket.deadline(1_000)
      assert :ok = Socket.write(socket, ["pi", "ng"])
      assert {:ok, "echo:"} = Socket.read(socket, 5, deadline)
      assert {:ok, "ping"} = Socket.read(socket, 0, deadline)
      assert :ok = Socket.close(socket)
      assert_received {:closed, "broker.example.com"}
    end

    test "WH-43: a host with a blocked address is never dialed", ctx do
      ScriptedSocket.serve("broker.example.com", &echo/2)
      Process.put({:dns, "broker.example.com"}, {:ok, [{203, 0, 114, 10}, {10, 0, 0, 5}]})

      broker = {"broker.example.com", 9093}

      assert {:error, error} = Socket.connect(ctx.policy, broker, ctx.options)
      assert %{class: :blocked, address: "10.0.0.5", reason: reason} = error
      assert is_binary(reason)
      refute_received {:dialed, _connection}
    end

    test "WH-43: an IPv4-mapped address is checked as its IPv4 form", ctx do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}
      Process.put({:dns, "broker.example.com"}, {:ok, [mapped]})

      assert {:error, %{class: :blocked, address: "127.0.0.1"}} =
               Socket.connect(ctx.policy, {"broker.example.com", 9093}, ctx.options)

      refute_received {:dialed, _connection}
    end

    test "WH-54: a metadata host name is refused before it is resolved", ctx do
      assert {:error, %{class: :blocked, reason: "metadata_host"}} =
               Socket.connect(ctx.policy, {"metadata.google.internal", 9093}, ctx.options)

      refute_received {:resolved, _host}
      refute_received {:dialed, _connection}
    end

    test "WH-43: an address literal is validated without a lookup", ctx do
      ScriptedSocket.serve("203.0.114.20", &echo/2)

      assert {:ok, socket} = Socket.connect(ctx.policy, {"203.0.114.20", 9093}, ctx.options)
      assert Socket.address(socket) == "203.0.114.20"

      assert {:error, %{class: :blocked, address: "169.254.169.254"}} =
               Socket.connect(ctx.policy, {"169.254.169.254", 9093}, ctx.options)

      assert {:error, %{class: :blocked, address: "192.168.0.1"}} =
               Socket.connect(ctx.policy, {"192.168.0.1", 9093}, ctx.options)

      refute_received {:resolved, _host}
    end

    test "WH-40: a port the installation does not allow is refused", ctx do
      assert {:error, %{class: :invalid, reason: "port_not_allowed"}} =
               Socket.connect(ctx.policy, {"broker.example.com", 9092}, ctx.options)

      refute_received {:resolved, _host}
      refute_received {:dialed, _connection}
    end

    test "WH-43: a host that is not a public name is refused", ctx do
      for host <- ["localhost", "broker", "bro ker.example.com", "0x7f.1"] do
        assert {:error, %{class: :invalid, reason: "invalid_host"}} =
                 Socket.connect(ctx.policy, {host, 9093}, ctx.options)
      end

      refute_received {:dialed, _connection}
    end

    test "WH-44: an allow-listed internal address is dialed on a self-hosted installation", ctx do
      {:ok, policy} =
        Policy.new(deployment: :self_hosted, extra_ports: [9093], allow_list: ["10.20.0.0/16"])

      broker = {"kafka.corp.example", 9093}
      ScriptedSocket.serve("kafka.corp.example", &echo/2)
      Process.put({:dns, "kafka.corp.example"}, {:ok, [{10, 20, 0, 5}]})

      assert {:ok, socket} = Socket.connect(policy, broker, ctx.options)
      assert Socket.address(socket) == "10.20.0.5"

      Process.put({:dns, "kafka.corp.example"}, {:ok, [{10, 30, 0, 5}]})
      assert {:error, %{class: :blocked}} = Socket.connect(policy, broker, ctx.options)
    end

    test "WH-43: a name that does not resolve and a refused connection are reported", ctx do
      Process.put({:dns, "gone.example.com"}, {:error, :nxdomain})

      assert {:error, %{class: :dns, reason: "nxdomain", address: nil}} =
               Socket.connect(ctx.policy, {"gone.example.com", 9093}, ctx.options)

      assert {:error, %{class: :connect, reason: "econnrefused", address: "203.0.114.10"}} =
               Socket.connect(ctx.policy, {"down.example.com", 9093}, ctx.options)
    end
  end

  describe "WH-24 deadline" do
    test "WH-24: a read after the deadline is a timeout", ctx do
      ScriptedSocket.serve("broker.example.com", &echo/2)
      {:ok, socket} = Socket.connect(ctx.policy, {"broker.example.com", 9093}, ctx.options)

      assert :ok = Socket.write(socket, "ping")
      past = Relay.Clock.monotonic_ms() - 1

      assert {:error, %{class: :timeout, reason: "total_timeout", address: "203.0.114.10"}} =
               Socket.read(socket, 0, past)

      assert {:error, %{class: :timeout, address: "203.0.114.10"}} =
               Socket.read(socket, 64, Socket.deadline(1_000))
    end
  end

  describe "WH-17 client certificate" do
    test "WH-17: a PEM chain and the PEM key of the credential become the certificate", ctx do
      der = ctx.chains.client[:cert]
      {type, key_der} = ctx.chains.client[:key]
      chain = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      key = :public_key.pem_encode([{type, key_der, :not_encrypted}])

      assert {:ok, certificate} = Socket.client_certificate(chain, Redacted.wrap(key))
      assert certificate.certificate == [der]
      assert Redacted.expose(certificate.key) == {type, key_der}
      refute inspect(certificate) =~ "PRIVATE"

      assert Socket.client_certificate(nil, nil) == {:ok, nil}
      assert Socket.client_certificate(certificate, nil) == {:ok, certificate}
      assert Socket.client_certificate(chain, Redacted.wrap("not a key")) == :error
      assert Socket.client_certificate("not a chain", Redacted.wrap(key)) == :error
      assert Socket.client_certificate(chain, nil) == :error
    end
  end

  describe "WH-41 TLS connection" do
    test "WH-41: the host name is the server name and the certificate is verified for it", ctx do
      serve(ctx.chains.server, "")

      assert {:ok, socket} = Socket.connect(ctx.policy, {@host, 9093}, loopback(ctx, []))
      assert_received {:dialed, %{address: {203, 0, 114, 10}, host: @host}}

      assert :ok = Socket.write(socket, "ping")
      assert {:ok, "echo:ping"} = Socket.read(socket, 9, Socket.deadline(5_000))
      assert_receive {:served, @host, "ping", nil}
      assert :ok = Socket.close(socket)
    end

    test "WH-41: a certificate for another host name is refused", ctx do
      other = chains("other.example.test")
      serve(other.server, "")
      options = loopback(ctx, ca_certificates: other.client[:cacerts])

      assert {:error, %{class: :tls, address: "203.0.114.10"}} =
               Socket.connect(ctx.policy, {@host, 9093}, options)

      refute_receive {:served, _sni, _data, _peer}, 100
    end

    test "WH-41: a certificate of an authority that is not trusted is refused", ctx do
      stranger = chains(@host)
      serve(stranger.server, "")

      options = loopback(ctx, [])

      assert {:error, %{class: :tls}} = Socket.connect(ctx.policy, {@host, 9093}, options)
    end

    test "WH-43: a connection that starts plain is upgraded with the same host name", ctx do
      serve(ctx.chains.server, "HELLO\r\n")
      options = loopback(ctx, mode: :plain)

      assert {:ok, plain} = Socket.connect(ctx.policy, {@host, 9093}, options)
      assert {:ok, "HELLO\r\n"} = Socket.read(plain, 7, Socket.deadline(5_000))
      assert {:ok, socket} = Socket.upgrade(plain)

      assert :ok = Socket.write(socket, "ping")
      assert {:ok, "echo:ping"} = Socket.read(socket, 9, Socket.deadline(5_000))
      assert_receive {:served, @host, "ping", nil}
    end

    test "WH-17: the client certificate is presented to a server that asks for it", ctx do
      mutual = [verify: :verify_peer, fail_if_no_peer_cert: true]
      serve(ctx.chains.server ++ mutual, "")
      key = Redacted.wrap(ctx.chains.client[:key])
      certificate = %{certificate: ctx.chains.client[:cert], key: key}
      options = loopback(ctx, client_certificate: certificate)

      assert {:ok, socket} = Socket.connect(ctx.policy, {@host, 9093}, options)
      assert :ok = Socket.write(socket, "ping")
      assert {:ok, "echo:ping"} = Socket.read(socket, 9, Socket.deadline(5_000))
      assert_receive {:served, @host, "ping", presented}
      assert presented == ctx.chains.client[:cert]
    end

    test "WH-24: a refused connection is a connection error", ctx do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)
      Process.put(:loopback_port, port)

      assert {:error, %{class: :connect, reason: "econnrefused"}} =
               Socket.connect(ctx.policy, {@host, 9093}, loopback(ctx, []))
    end
  end
end
