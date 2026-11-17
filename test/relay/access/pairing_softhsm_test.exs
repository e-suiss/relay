defmodule Relay.Access.PairingSoftHSMTest do
  use ExUnit.Case, async: false

  alias Relay.Access.Pairing.KernelSigner
  alias Relay.Keys.Port, as: KeyPort
  alias RelayTest.AccessKernel

  @moduletag :integration

  @now 1_794_000_060_000
  @pin "1234"
  @token "relay-pairing-test"
  @executable Path.expand("../../../native/pkcs11_port/target/release/pkcs11_port", __DIR__)
  @modules [
    "/usr/lib/softhsm/libsofthsm2.so",
    "/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so",
    "/opt/homebrew/lib/softhsm/libsofthsm2.so",
    "/usr/local/lib/softhsm/libsofthsm2.so"
  ]

  setup_all do
    module = System.get_env("SOFTHSM2_MODULE") || Enum.find(@modules, &File.exists?/1)
    assert module, "SoftHSM module not found; set SOFTHSM2_MODULE"
    assert File.exists?(@executable), "build the port program first: native/build.sh"

    name = "relay-pairing-softhsm-#{System.unique_integer([:positive])}"
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
    service = ~w(--keypairgen --key-type EC:edwards25519 --label access-service --id 01)
    other = ~w(--keypairgen --key-type EC:edwards25519 --label other-service --id 02)
    run!("pkcs11-tool", tool ++ service)
    run!("pkcs11-tool", tool ++ other)
    pin_file = Path.join(dir, "pin")
    File.write!(pin_file, @pin <> "\n")
    %{pkcs11_module: module, pin_file: pin_file}
  end

  setup %{pkcs11_module: module, pin_file: pin_file} do
    sha256 = (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()

    start_supervised!(
      {KeyPort,
       executable: @executable, sha256: sha256, module: module, token: @token, pin_file: pin_file}
    )

    keys = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, KeyPort)
    on_exit(fn -> Application.put_env(:relay, :keys, keys) end)
    {:ok, <<_::256>> = key} = KeyPort.public_key(:ed25519, "access-service")
    %{key: key}
  end

  defp run!(cmd, args) do
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    assert status == 0, "#{cmd} failed: #{out}"
    out
  end

  test "E-101, TN-63: the port recomputes the intent digests and the token signs both statements under the service key",
       %{key: key} do
    target = AccessKernel.target(key, @now)
    pairing = Map.put(target, :now_ms, @now)

    assert {:ok, %{ais: ais, register_ais: register_ais}} = KernelSigner.sign(target, key, @now)

    create = AccessKernel.statement(pairing, target.instance_create)
    register = AccessKernel.statement(pairing, target.party_register)
    assert AccessKernel.signed?(ais, create, target.kid, key)
    assert AccessKernel.signed?(register_ais, register, target.kid, key)
    refute AccessKernel.signed?(ais, register, target.kid, key)
  end

  test "E-101: a target without a registration gets only the instance statement", %{key: key} do
    target = AccessKernel.target(key, @now, party_register: false)

    assert {:ok, %{ais: ais, register_ais: nil}} = KernelSigner.sign(target, key, @now)

    statement = AccessKernel.statement(Map.put(target, :now_ms, @now), target.instance_create)
    assert AccessKernel.signed?(ais, statement, target.kid, key)
  end

  test "E-101: a wrong kid, nonce, window, basis or intent digest is refused by the port and nothing is signed",
       %{key: key} do
    for {code, tampered} <- AccessKernel.tampered(AccessKernel.target(key, @now)) do
      assert {code, KernelSigner.sign(tampered, key, @now)} ==
               {code, {:error, {:unsignable, code}}}
    end
  end

  test "E-101: less than 60 seconds of validity is refused by the port", %{key: key} do
    target = AccessKernel.target(key, @now)

    assert KernelSigner.sign(target, key, target.valid_until_ms - 59_999) ==
             {:error, {:unsignable, "pairing-validity"}}

    assert {:ok, _signed} = KernelSigner.sign(target, key, target.valid_until_ms - 60_000)
  end

  test "E-101: a challenge for another key is refused by its kid, and a missing key signs nothing",
       %{key: key} do
    {:ok, other} = KeyPort.public_key(:ed25519, "other-service")
    target = AccessKernel.target(other, @now)
    assert KernelSigner.sign(target, key, @now) == {:error, {:unsignable, "pairing-kid"}}

    request = target |> Map.drop([:status, :access_environment]) |> Map.put(:now_ms, @now)
    assert {:ok, [_ais, _register_ais]} = KeyPort.sign_pairing("other-service", request)

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.sign_pairing("absent-service", request)
  end
end
