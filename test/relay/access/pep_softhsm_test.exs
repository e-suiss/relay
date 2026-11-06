defmodule Relay.Access.PepSoftHSMTest do
  use ExUnit.Case, async: false

  alias Relay.Access.Pep
  alias Relay.Keys.Port, as: KeyPort
  alias RelayTest.FakeAdp

  @moduletag :integration
  @moduletag :tmp_dir

  @pin "1234"
  @token "relay-pep-test"
  @executable Path.expand("../../../native/pkcs11_port/target/release/pkcs11_port", __DIR__)
  @modules [
    "/usr/lib/softhsm/libsofthsm2.so",
    "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so",
    "/opt/homebrew/lib/softhsm/libsofthsm2.so",
    "/usr/local/lib/softhsm/libsofthsm2.so"
  ]
  @question %{"subject" => %{"type" => "user", "id" => "op-1"}, "action" => %{"name" => "read"}}

  setup_all do
    module = System.get_env("SOFTHSM2_MODULE") || Enum.find(@modules, &File.exists?/1)
    assert module, "SoftHSM module not found; set SOFTHSM2_MODULE"
    assert File.exists?(@executable), "build the port program first: native/build.sh"

    name = "relay-pep-softhsm-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(Path.join(dir, "tokens"))
    conf = Path.join(dir, "softhsm2.conf")
    File.write!(conf, "directories.tokendir = #{dir}/tokens\nobjectstore.backend = file\n")
    previous = System.get_env("SOFTHSM2_CONF")
    System.put_env("SOFTHSM2_CONF", conf)

    on_exit(fn ->
      if previous,
        do: System.put_env("SOFTHSM2_CONF", previous),
        else: System.delete_env("SOFTHSM2_CONF")

      File.rm_rf!(dir)
    end)

    run!(
      "softhsm2-util",
      ~w(--init-token --free --label #{@token} --pin #{@pin} --so-pin 12345678)
    )

    tool = ~w(--module #{module} --token-label #{@token} --login --pin #{@pin})
    keypair = ~w(--keypairgen --key-type EC:prime256v1 --label access-pep --id 01)
    run!("pkcs11-tool", tool ++ keypair)
    pin_file = Path.join(dir, "pin")
    File.write!(pin_file, @pin <> "\n")
    %{pkcs11_module: module, pin_file: pin_file}
  end

  setup %{pkcs11_module: module, pin_file: pin_file, tmp_dir: dir} do
    sha256 = (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()

    start_supervised!(
      {KeyPort,
       executable: @executable, sha256: sha256, module: module, token: @token, pin_file: pin_file}
    )

    keys = Application.fetch_env!(:relay, :keys)
    access = Application.get_env(:relay, Relay.Access)
    Application.put_env(:relay, :keys, KeyPort)
    :ok = Pep.forget()

    on_exit(fn ->
      Application.put_env(:relay, :keys, keys)
      Application.put_env(:relay, Relay.Access, access)
      Pep.forget()
    end)

    %{dir: dir, access: access}
  end

  defp run!(cmd, args) do
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    assert status == 0, "#{cmd} failed: #{out}"
    out
  end

  defp pem(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  defp certificates(ders), do: for(der <- ders, do: {:Certificate, der, :not_encrypted})

  test "E-102: the CSR of the token's PEP key verifies with openssl", ctx do
    assert {:ok, der} = Pep.csr()
    path = pem(ctx.dir, "relay-pep.csr", [{:CertificationRequest, der, :not_encrypted}])
    run!("openssl", ["req", "-in", path, "-noout", "-verify"])
    text = run!("openssl", ["req", "-in", path, "-noout", "-text"])
    assert text =~ "CN = relay-pep" or text =~ "CN=relay-pep"
    assert text =~ "prime256v1"
  end

  test "E-102, TN-63: the TLS client signature of an evaluation is made inside the token", ctx do
    {:ok, point} = KeyPort.public_key(:es256, "access-pep")
    certificates = FakeAdp.certificates(point)
    {:ok, port} = FakeAdp.start(certificates)

    paths = [
      pep_certificate: pem(ctx.dir, "pep.crt", certificates([certificates.pep])),
      ca_certificates: pem(ctx.dir, "ca.crt", certificates(certificates.cacerts))
    ]

    Application.put_env(:relay, Relay.Access, Keyword.merge(ctx.access, paths))
    x5t = FakeAdp.x5t(certificates.pep)
    url = "https://localhost:#{port}/access/v1/evaluation"

    assert {:ok, %{decision: true, receipt: %{sign1: _sign1}}} = Pep.evaluate(url, @question)
    assert_received {:fake_adp, :evaluation, ^x5t, @question}
  end
end
