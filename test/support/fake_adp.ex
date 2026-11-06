defmodule RelayTest.FakeAdp do
  @moduledoc """
  A fake Access decision point for the PEP tests (E-102), on the loopback interface with no network beyond it. `certificates/1` makes a test CA with a server certificate for `localhost` and Relay's PEP certificate for a given P-256 public key, both issued by the CA. `start/2` serves HTTP/1.1 over TLS 1.3 and takes only a client certificate of that CA, as Access does: each request is answered with the decision `answer.(x5t)` builds for the `x5t#S256` of the presented certificate, and the calling process receives `{:fake_adp, :evaluation, x5t, body}`.
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @ec_public_key {1, 2, 840, 10045, 2, 1}
  @prime256v1 {1, 2, 840, 10045, 3, 1, 7}
  @base [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  @doc "A test CA with `:server`, the options of a server certificate for `localhost`, `:cacerts`, the CA, and `:pep`, a certificate for `point` (an uncompressed P-256 key) issued by the CA from a template peer certificate."
  @spec certificates(binary()) :: %{server: keyword(), cacerts: [binary()], pep: binary()}
  def certificates(<<4, _::binary-64>> = point) do
    key = {:namedCurve, @prime256v1}
    root = :public_key.pkix_test_root_cert(~c"fake access ca", key: key, digest: :sha256)
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}

    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: root,
          intermediates: [],
          peer: [key: key, digest: :sha256, extensions: [san]]
        },
        client_chain: %{root: root, intermediates: [], peer: [key: key, digest: :sha256]}
      })

    %{
      server: Keyword.take(server, [:cert, :key]),
      cacerts: [root.cert],
      pep: reissue(Keyword.fetch!(client, :cert), point, root.key)
    }
  end

  @doc "The `x5t#S256` of a DER certificate."
  @spec x5t(binary()) :: String.t()
  def x5t(der), do: Base.url_encode64(:crypto.hash(:sha256, der), padding: false)

  @doc "An allow decision for `x5t` with a receipt, shaped as Access answers."
  @spec allow(String.t()) :: map()
  def allow(x5t) do
    %{
      "decision" => true,
      "context" => %{
        "basis_ref" => "basis-1",
        "pep" => x5t,
        "receipt" => %{"sign1" => "c2lnbjE", "excerpt" => "ZXhjZXJwdA"},
        "versions" => %{"core" => 1, "meta_schema" => 1}
      }
    }
  end

  @doc "Starts the decision point with the certificates of `certificates/1` and returns its port; it lives as long as the calling process."
  @spec start(map(), (String.t() -> map())) :: {:ok, :inet.port_number()}
  def start(certificates, answer \\ &allow/1) when is_function(answer, 1) do
    owner = self()

    tls =
      certificates.server ++
        [
          cacerts: certificates.cacerts,
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          versions: [:"tlsv1.3"]
        ]

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, listen} = :ssl.listen(0, @base ++ tls)
        {:ok, {_ip, port}} = :ssl.sockname(listen)
        send(owner, {:fake_adp_port, self(), port})
        accept(listen, owner, answer)
      end)

    receive do
      {:fake_adp_port, ^pid, port} -> {:ok, port}
    after
      5_000 -> raise "the fake decision point did not start"
    end
  end

  defp reissue(template, point, ca_key) do
    {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(template, :otp)
    algorithm = {:PublicKeyAlgorithm, @ec_public_key, {:namedCurve, @prime256v1}}
    spki = {:OTPSubjectPublicKeyInfo, algorithm, {:ECPoint, point}}
    :public_key.pkix_sign(put_elem(tbs, 7, spki), ca_key)
  end

  defp accept(listen, owner, answer) do
    with {:ok, transport} <- :ssl.transport_accept(listen),
         {:ok, socket} <- :ssl.handshake(transport, 10_000) do
      {:ok, pid} = Task.start(fn -> serve(socket, owner, answer) end)
      :ok = :ssl.controlling_process(socket, pid)
      send(pid, :go)
    end

    accept(listen, owner, answer)
  end

  defp serve(socket, owner, answer) do
    receive do
      :go -> loop(socket, owner, answer)
    end
  end

  defp loop(socket, owner, answer) do
    with {:ok, head, rest} <- head(socket, ""),
         {:ok, body} <- body(socket, rest, content_length(head)),
         {:ok, der} <- :ssl.peercert(socket) do
      x5t = x5t(der)
      send(owner, {:fake_adp, :evaluation, x5t, Jason.decode!(body)})
      json = Jason.encode!(answer.(x5t))
      size = Integer.to_string(byte_size(json))
      response = "content-type: application/json\r\ncontent-length: " <> size <> "\r\n\r\n"
      :ok = :ssl.send(socket, ["HTTP/1.1 200 OK\r\n", response, json])
      loop(socket, owner, answer)
    else
      _closed -> :ssl.close(socket)
    end
  end

  defp head(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] -> {:ok, head, rest}
      [_partial] -> with {:ok, data} <- :ssl.recv(socket, 0), do: head(socket, buffer <> data)
    end
  end

  defp body(_socket, rest, length) when byte_size(rest) >= length, do: {:ok, rest}

  defp body(socket, rest, length) do
    with {:ok, data} <- :ssl.recv(socket, length - byte_size(rest), 10_000),
         do: {:ok, rest <> data}
  end

  defp content_length(head) do
    case Regex.run(~r/^content-length:\s*(\d+)\s*$/im, head) do
      [_line, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end
end
