defmodule Relay.Webhooks.EgressTransportTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Egress.Transport.Pinned

  @host "hooks.example.test"
  @request %{
    method: "POST",
    path: "/hooks?x=1",
    headers: [{"content-type", "application/json"}, {"webhook-id", "evt_1"}],
    body: ~s({"a":1})
  }
  @listen [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  setup_all do
    %{chains: chains(@host)}
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

  defp serve(tls, handler) do
    test = self()
    {:ok, listen} = :ssl.listen(0, @listen ++ tls)
    {:ok, {_ip, port}} = :ssl.sockname(listen)
    {:ok, _pid} = Task.start_link(fn -> accept(listen, test, handler) end)
    port
  end

  defp accept(listen, test, handler) do
    case :ssl.transport_accept(listen, 10_000) do
      {:ok, transport} -> handshake(transport, listen, test, handler)
      {:error, :timeout} -> accept(listen, test, handler)
      {:error, _closed} -> :ok
    end
  end

  defp handshake(transport, listen, test, handler) do
    case :ssl.handshake(transport, 10_000) do
      {:ok, socket} -> exchange(socket, test, handler)
      {:error, _reason} -> send(test, :handshake_failed)
    end

    accept(listen, test, handler)
  end

  defp exchange(socket, test, handler) do
    {:ok, information} = :ssl.connection_information(socket, [:sni_hostname])
    sni = to_string(information[:sni_hostname])
    send(test, {:served, sni, read(socket, ""), peer(socket)})
    handler.(socket)
    :ssl.close(socket)
  end

  defp peer(socket) do
    case :ssl.peercert(socket) do
      {:ok, certificate} -> certificate
      {:error, _reason} -> nil
    end
  end

  defp read(socket, received) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> more(socket, received <> data)
      {:error, _reason} -> received
    end
  end

  defp more(socket, received) do
    if complete?(received), do: received, else: read(socket, received)
  end

  defp complete?(received) do
    case String.split(received, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= content_length(head)
      [_partial] -> false
    end
  end

  defp content_length(head) do
    case Regex.run(~r/content-length: (\d+)/i, head) do
      [_line, length] -> String.to_integer(length)
      nil -> 0
    end
  end

  defp answer(status, headers, body) do
    lines = ["HTTP/1.1 #{status}", "content-length: #{byte_size(body)}" | headers]
    fn socket -> :ssl.send(socket, Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body) end
  end

  defp connection(port, chains, extra \\ %{}) do
    Map.merge(
      %{
        address: {127, 0, 0, 1},
        host: @host,
        port: port,
        connect_timeout_ms: 5_000,
        total_timeout_ms: 10_000,
        max_response_bytes: 8_192,
        client_certificate: nil,
        ca_certificates: chains.client[:cacerts],
        proxy: nil
      },
      extra
    )
  end

  describe "WH-41 pinned connection" do
    test "WH-41: the connection goes to the given address, the host name is SNI and Host", ctx do
      port = serve(ctx.chains.server, answer("200 OK", ["x-served: yes"], "done"))

      assert {:ok, response} = Pinned.request(connection(port, ctx.chains), @request)
      assert %{status: 200, body: "done", truncated: false} = response
      assert {"x-served", "yes"} in response.headers

      assert_receive {:served, @host, received, nil}
      assert received =~ "POST /hooks?x=1 HTTP/1.1\r\n"
      assert received =~ ~r/\r\nhost: hooks\.example\.test:#{port}\r\n/i
      assert received =~ ~r/\r\nwebhook-id: evt_1\r\n/i
      assert String.ends_with?(received, ~s(\r\n\r\n{"a":1}))
    end

    test "WH-41: a certificate for another host name is refused", ctx do
      other = chains("other.example.test")
      port = serve(other.server, answer("200 OK", [], "done"))
      connection = connection(port, ctx.chains, %{ca_certificates: other.client[:cacerts]})

      assert {:error, %{class: :tls, reason: "tls_alert_" <> _alert}} =
               Pinned.request(connection, @request)

      refute_receive {:served, _sni, _received, _peer}, 100
    end

    test "WH-41: a certificate of an authority that is not trusted is refused", ctx do
      stranger = chains(@host)
      port = serve(stranger.server, answer("200 OK", [], "done"))

      assert {:error, %{class: :tls}} = Pinned.request(connection(port, ctx.chains), @request)
      refute_receive {:served, _sni, _received, _peer}, 100
    end
  end

  describe "WH-42 redirects" do
    test "WH-42: a redirect is returned as it is and no second request is made", ctx do
      location = "location: https://169.254.169.254/latest/meta-data/"
      port = serve(ctx.chains.server, answer("302 Found", [location], ""))

      assert {:ok, %{status: 302, headers: headers, body: ""}} =
               Pinned.request(connection(port, ctx.chains), @request)

      assert {"location", "https://169.254.169.254/latest/meta-data/"} in headers
      assert_receive {:served, @host, _received, nil}
      refute_receive {:served, _sni, _received, _peer}, 200
    end
  end

  describe "WH-24 timeouts and response size" do
    test "WH-24: at most the allowed bytes of the response body are read", ctx do
      port = serve(ctx.chains.server, answer("200 OK", [], String.duplicate("a", 200_000)))

      assert {:ok, %{status: 200, body: body, truncated: true}} =
               Pinned.request(connection(port, ctx.chains), @request)

      assert body == String.duplicate("a", 8_192)
    end

    test "WH-24: a body of exactly the allowed size is not marked as cut", ctx do
      port = serve(ctx.chains.server, answer("200 OK", [], String.duplicate("a", 64)))
      connection = connection(port, ctx.chains, %{max_response_bytes: 64})

      assert {:ok, %{body: body, truncated: false}} = Pinned.request(connection, @request)
      assert byte_size(body) == 64

      assert {:ok, %{body: "", truncated: true}} =
               Pinned.request(%{connection | max_response_bytes: 0}, @request)
    end

    test "WH-24: the total timeout ends a request whose response never comes", ctx do
      port = serve(ctx.chains.server, fn _socket -> Process.sleep(3_000) end)
      connection = connection(port, ctx.chains, %{total_timeout_ms: 400})

      assert {:error, %{class: :timeout}} = Pinned.request(connection, @request)
    end

    test "WH-24: a response whose body stalls is returned with what arrived", ctx do
      stall = fn socket ->
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc")
        Process.sleep(5_000)
      end

      port = serve(ctx.chains.server, stall)
      connection = connection(port, ctx.chains, %{total_timeout_ms: 2_000})

      assert {:ok, %{status: 200, body: "abc", truncated: true}} =
               Pinned.request(connection, @request)
    end

    test "WH-24: a refused connection is a connection error", ctx do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)

      assert {:error, %{class: :connect, reason: "econnrefused"}} =
               Pinned.request(connection(port, ctx.chains), @request)
    end
  end

  describe "WH-17 mutual TLS" do
    test "WH-17: the client certificate is presented to a server that asks for it", ctx do
      mutual = [verify: :verify_peer, fail_if_no_peer_cert: true]
      port = serve(ctx.chains.server ++ mutual, answer("200 OK", [], "done"))

      certificate = %{
        certificate: ctx.chains.client[:cert],
        key: Relay.Redacted.wrap(ctx.chains.client[:key])
      }

      connection = connection(port, ctx.chains, %{client_certificate: certificate})

      assert {:ok, %{status: 200}} = Pinned.request(connection, @request)
      assert_receive {:served, @host, _received, presented}
      assert presented == ctx.chains.client[:cert]
    end

    test "WH-17: without the client certificate such a server gives no response", ctx do
      mutual = [verify: :verify_peer, fail_if_no_peer_cert: true]
      port = serve(ctx.chains.server ++ mutual, answer("200 OK", [], "done"))

      assert {:error, %{class: class}} = Pinned.request(connection(port, ctx.chains), @request)
      assert class in [:tls, :connect, :protocol]
    end
  end
end
