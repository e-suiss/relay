defmodule Relay.Access.PepTest do
  use ExUnit.Case, async: false

  import Mox

  alias Relay.Access.Pep
  alias Relay.Operators.Access, as: OperatorAccess
  alias Relay.Operators.Access.Http
  alias RelayTest.FakeAdp

  @moduletag :tmp_dir

  @question %{"subject" => %{"type" => "user", "id" => "op-1"}, "action" => %{"name" => "read"}}

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: dir} do
    {:ok, point} = Relay.Keys.public_key(:es256, "access-pep")
    certificates = FakeAdp.certificates(point)
    {:ok, port} = FakeAdp.start(certificates)
    previous = Application.get_env(:relay, Relay.Access)

    paths = [
      pep_certificate: pem(dir, "pep.crt", [certificates.pep]),
      ca_certificates: pem(dir, "ca.crt", certificates.cacerts)
    ]

    Application.put_env(:relay, Relay.Access, Keyword.merge(previous, paths))
    :ok = Pep.forget()

    on_exit(fn ->
      Application.put_env(:relay, Relay.Access, previous)
      Pep.forget()
    end)

    url = "https://localhost:#{port}/access/v1/evaluation"
    %{url: url, certificates: certificates, dir: dir}
  end

  defp pem(dir, name, ders) do
    path = Path.join(dir, name)
    entries = for der <- ders, do: {:Certificate, der, :not_encrypted}
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  defp configure(key, path) do
    Application.put_env(:relay, Relay.Access, Keyword.put(Relay.Access.config(), key, path))
    :ok = Pep.forget()
  end

  defp tlv(<<tag, size, value::binary-size(size), rest::binary>>) when size < 0x80,
    do: {tag, value, rest}

  defp tlv(<<tag, 0x81, size, value::binary-size(size), rest::binary>>),
    do: {tag, value, rest}

  defp tlv(<<tag, 0x82, size::16, value::binary-size(size), rest::binary>>),
    do: {tag, value, rest}

  describe "E-102 the PEP certificate" do
    test "E-102: the certificate signing request names the PEP key and is signed by it" do
      {:ok, point} = Relay.Keys.public_key(:es256, "access-pep")
      assert {:ok, der} = Pep.csr()

      assert {:CertificationRequest, _info, _algorithm, _signature} =
               :public_key.der_decode(:CertificationRequest, der)

      {0x30, request, ""} = tlv(der)
      {0x30, _info, rest} = tlv(request)
      info = binary_part(request, 0, byte_size(request) - byte_size(rest))
      {0x30, <<0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02>>, rest} = tlv(rest)
      {0x03, <<0, signature::binary>>, ""} = tlv(rest)

      assert :binary.match(info, point) != :nomatch
      assert :binary.match(info, "relay-pep") != :nomatch
      assert :crypto.verify(:ecdsa, :sha256, info, signature, [point, :secp256r1])
    end

    test "E-102: the certificate signing request is printed as PEM" do
      printed = ExUnit.CaptureIO.capture_io(fn -> :ok = Pep.print_csr() end)
      assert [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(printed)
      assert {:ok, ^der} = Pep.csr()
    end

    test "E-102: a certificate of another key is refused before any call", ctx do
      {:ok, other} = Relay.Keys.public_key(:es256, "not-the-pep")
      other_pep = FakeAdp.certificates(other).pep
      configure(:pep_certificate, pem(ctx.dir, "other.crt", [other_pep]))

      assert {:error, %Relay.Error{code: :access_unreachable, message: message}} =
               Pep.evaluate(ctx.url, @question)

      assert message =~ "not for Relay's PEP key"
      refute_received {:fake_adp, :evaluation, _x5t, _body}
    end

    test "E-102: a missing certificate is access_unreachable", ctx do
      configure(:pep_certificate, Path.join(ctx.dir, "absent.crt"))

      assert {:error, %Relay.Error{code: :access_unreachable}} = Pep.evaluate(ctx.url, @question)
      assert {:error, %Relay.Error{code: :access_unreachable}} = Pep.x5t()
    end
  end

  describe "E-102 decisions over mutual TLS" do
    test "E-102: an evaluation is sent with the PEP certificate and its receipt is kept", ctx do
      x5t = FakeAdp.x5t(ctx.certificates.pep)

      assert {:ok, %{decision: true, context: %{"pep" => ^x5t}, receipt: receipt}} =
               Pep.evaluate(ctx.url, @question)

      assert receipt == %{sign1: "c2lnbjE", excerpt: "ZXhjZXJwdA"}
      assert_received {:fake_adp, :evaluation, ^x5t, @question}
      assert Pep.x5t() == {:ok, x5t}
    end

    test "E-102: the TLS handshake signature is made by the PEP key in the key store", ctx do
      test = self()
      previous = Application.fetch_env!(:relay, :keys)
      Application.put_env(:relay, :keys, Relay.KeysMock)
      on_exit(fn -> Application.put_env(:relay, :keys, previous) end)
      stub_with(Relay.KeysMock, RelayTest.Keys)

      expect(Relay.KeysMock, :sign, fn :es256, "access-pep", message ->
        send(test, {:signed, message})
        RelayTest.Keys.sign(:es256, "access-pep", message)
      end)

      assert {:ok, %{decision: true}} = Pep.evaluate(ctx.url, @question)
      assert_received {:signed, message}
      assert <<pad::binary-64, "TLS 1.3, client CertificateVerify", 0, _::binary>> = message
      assert pad == String.duplicate(" ", 64)
    end

    test "E-102: a decision point not certified by the Access CA is refused", ctx do
      {:ok, point} = Relay.Keys.public_key(:es256, "access-pep")
      other_ca = FakeAdp.certificates(point).cacerts
      configure(:ca_certificates, pem(ctx.dir, "other-ca.crt", other_ca))

      assert {:error, %Relay.Error{code: :access_unreachable}} = Pep.evaluate(ctx.url, @question)
      refute_received {:fake_adp, :evaluation, _x5t, _body}
    end

    test "E-102, E-27: an operator step-up decision goes through the PEP", ctx do
      previous = Application.get_env(:relay, OperatorAccess)

      discovery = %{
        "issuer" => "https://access.test",
        "authorization_endpoint" => "https://access.test/oauth2/authorize",
        "token_endpoint" => "https://access.test/oauth2/token",
        "jwks" => %{"keys" => []},
        "access_evaluation_endpoint" => ctx.url
      }

      config = Keyword.put(previous, :discovery, {Function, :identity, [{:ok, discovery}]})
      Application.put_env(:relay, OperatorAccess, config)
      on_exit(fn -> Application.put_env(:relay, OperatorAccess, previous) end)
      request = %{subject: "op-1", action: "tenant.suspend", resource: %{type: "tenant", id: "t"}}
      x5t = FakeAdp.x5t(ctx.certificates.pep)

      assert {:ok, %{decision: true, ref: "basis-1"}} = Http.evaluate(request)
      assert_received {:fake_adp, :evaluation, ^x5t, %{"subject" => %{"id" => "op-1"}}}
    end
  end
end
