defmodule Relay.Keys.SoftHSMTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Relay.Keys.Port, as: KeyPort
  alias Relay.Redacted

  @moduletag :integration
  @moduletag :tmp_dir

  @pin "1234"
  @hmac_key :binary.copy(<<0x0B>>, 32)
  @token "relay-test"
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

    dir = Path.join(System.tmp_dir!(), "relay-softhsm-#{System.unique_integer([:positive])}")
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
    run!("pkcs11-tool", tool ++ ~w(--keypairgen --key-type EC:prime256v1 --label es256 --id 01))
    run!("pkcs11-tool", tool ++ ~w(--keypairgen --key-type rsa:2048 --label rs256 --id 02))

    run!(
      "pkcs11-tool",
      tool ++ ~w(--keypairgen --key-type EC:edwards25519 --label ed25519 --id 03)
    )

    run!("pkcs11-tool", tool ++ ~w(--keygen --key-type AES:32 --label kek --id 04))
    run!("pkcs11-tool", tool ++ ~w(--keygen --key-type AES:32 --label other-kek --id 05))
    run!("pkcs11-tool", tool ++ ~w(--keygen --key-type GENERIC:32 --label bidx --id 06))

    known = Path.join(dir, "bidx-known")
    File.write!(known, @hmac_key)

    run!(
      "pkcs11-tool",
      tool ++
        ["--write-object", known] ++
        ~w(--type secrkey --key-type GENERIC:32 --label bidx-known --id 07 --sensitive)
    )

    secret = Path.join(dir, "smtp")
    File.write!(secret, "smtp-password")

    run!(
      "pkcs11-tool",
      tool ++ ["--write-object", secret] ++ ~w(--type data --label smtp --private)
    )

    pin_file = Path.join(dir, "pin")
    File.write!(pin_file, @pin <> "\n")
    %{pkcs11_module: module, pin_file: pin_file, dir: dir}
  end

  defp sha256, do: (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()

  defp run!(cmd, args) do
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    assert status == 0, "#{cmd} failed: #{out}"
  end

  setup %{pkcs11_module: module, pin_file: pin_file} do
    name = {:global, make_ref()}

    start_supervised!(
      {KeyPort,
       name: name,
       executable: @executable,
       sha256: sha256(),
       module: module,
       token: @token,
       pin_file: pin_file}
    )

    %{keys: name}
  end

  defp der(<<r::binary-size(32), s::binary-size(32)>>) do
    :public_key.der_encode(
      :"ECDSA-Sig-Value",
      {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
    )
  end

  test "TN-63: the token answers", %{keys: keys} do
    assert KeyPort.ping(keys) == :ok
  end

  test "TN-28: ES256 signatures are 64-byte R‖S and verify against the exported point", %{
    keys: keys
  } do
    assert {:ok, <<4, _::binary-size(64)>> = point} = KeyPort.public_key(keys, :es256, "es256")

    for i <- 1..300 do
      message = "header.claims.#{i}"

      assert {:ok, <<_::binary-size(64)>> = signature} =
               KeyPort.sign(keys, :es256, "es256", message)

      assert :crypto.verify(:ecdsa, :sha256, message, der(signature), [point, :secp256r1])
    end
  end

  test "TN-30: RS256 signatures verify against the exported modulus and exponent", %{keys: keys} do
    assert {:ok, {modulus, exponent}} = KeyPort.public_key(keys, :rs256, "rs256")
    assert {:ok, signature} = KeyPort.sign(keys, :rs256, "rs256", "assertion")
    assert :crypto.verify(:rsa, :sha256, "assertion", signature, [exponent, modulus])
  end

  test "OP-63: Ed25519 checkpoint signatures verify against the exported key", %{keys: keys} do
    assert {:ok, <<_::binary-size(32)>> = public} = KeyPort.public_key(keys, :ed25519, "ed25519")

    assert {:ok, <<_::binary-size(64)>> = signature} =
             KeyPort.sign(keys, :ed25519, "ed25519", "note")

    assert :crypto.verify(:eddsa, :none, "note", signature, [public, :ed25519])
  end

  test "TN-27: a data key round-trips under the KEK and is bound to its context", %{keys: keys} do
    data_key = :crypto.strong_rand_bytes(32)
    assert {:ok, wrapped} = KeyPort.wrap(keys, "kek", "tenant-1", Redacted.wrap(data_key))
    assert byte_size(wrapped) == 12 + 32 + 16
    assert :binary.match(wrapped, data_key) == :nomatch

    assert {:ok, unwrapped} = KeyPort.unwrap(keys, "kek", "tenant-1", wrapped)
    assert Redacted.expose(unwrapped) == data_key

    assert {:ok, again} = KeyPort.wrap(keys, "kek", "tenant-1", Redacted.wrap(data_key))
    assert again != wrapped

    assert {:error, %Relay.Error{code: :key_integrity}} =
             KeyPort.unwrap(keys, "kek", "tenant-2", wrapped)

    assert {:error, %Relay.Error{code: :key_integrity}} =
             KeyPort.unwrap(keys, "other-kek", "tenant-1", wrapped)

    <<head::binary-size(20), byte, rest::binary>> = wrapped
    tampered = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

    assert {:error, %Relay.Error{code: :key_integrity}} =
             KeyPort.unwrap(keys, "kek", "tenant-1", tampered)

    assert {:error, %Relay.Error{code: :key_integrity}} =
             KeyPort.unwrap(keys, "kek", "tenant-1", "short")
  end

  test "TN-66: the blind index HMAC is computed inside the token", %{keys: keys} do
    message = Redacted.wrap("ada@example.com")

    assert KeyPort.hmac_sha256(keys, "bidx-known", message) ==
             {:ok, :crypto.mac(:hmac, :sha256, @hmac_key, "ada@example.com")}

    assert {:ok, <<_::256>> = mac} = KeyPort.hmac_sha256(keys, "bidx", message)
    assert KeyPort.hmac_sha256(keys, "bidx", message) == {:ok, mac}
    refute KeyPort.hmac_sha256(keys, "bidx", Redacted.wrap("other@example.com")) == {:ok, mac}

    assert {:error, %Relay.Error{code: :key_not_found}} = KeyPort.read_secret(keys, "bidx")

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.hmac_sha256(keys, "kek", message)
  end

  test "TN-67 (1): an HMAC key generated in the token stays there and computes blind indexes",
       %{keys: keys} = ctx do
    label = "bidx-generated-#{System.unique_integer([:positive])}"
    message = Redacted.wrap("ada@example.com")

    assert KeyPort.generate_key(keys, :hmac_sha256, label, <<1::128>>) == :ok
    assert {:ok, <<_::256>> = mac} = KeyPort.hmac_sha256(keys, label, message)
    assert KeyPort.hmac_sha256(keys, label, message) == {:ok, mac}

    assert {:error, %Relay.Error{code: :key_exists}} =
             KeyPort.generate_key(keys, :hmac_sha256, label, <<2::128>>)

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.wrap(keys, label, "aad", Redacted.wrap(<<0::256>>))

    assert {:error, %Relay.Error{code: :key_not_found}} = KeyPort.read_secret(keys, label)

    object = secret_key(ctx, label)
    assert object =~ ~r/never extractable/
    assert object =~ ~r/\bsensitive\b/
    assert object =~ ~r/ID: *00000000000000000000000000000001/
  end

  test "TN-67 (1): an AES-256 key generated in the token wraps and unwraps but is never extractable",
       %{keys: keys} = ctx do
    label = "aes-generated-#{System.unique_integer([:positive])}"
    data_key = :crypto.strong_rand_bytes(32)

    assert KeyPort.generate_key(keys, :aes_256, label, <<3::128>>) == :ok
    assert {:ok, wrapped} = KeyPort.wrap(keys, label, "tenant-1", Redacted.wrap(data_key))
    assert {:ok, unwrapped} = KeyPort.unwrap(keys, label, "tenant-1", wrapped)
    assert Redacted.expose(unwrapped) == data_key

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.hmac_sha256(keys, label, Redacted.wrap("m"))

    object = secret_key(ctx, label)
    assert object =~ ~r/AES length 32/
    assert object =~ ~r/never extractable/
  end

  defp secret_key(%{pkcs11_module: module}, label) do
    {out, 0} =
      System.cmd(
        "pkcs11-tool",
        ~w(--module #{module} --token-label #{@token} --login --pin #{@pin} --list-objects --type secrkey --label #{label}),
        stderr_to_stdout: true
      )

    assert out =~ "label:"
    out
  end

  test "TN-26: a secret data object is read back redacted", %{keys: keys} do
    assert {:ok, secret} = KeyPort.read_secret(keys, "smtp")
    assert Redacted.expose(secret) == "smtp-password"
    refute inspect(secret) =~ "smtp-password"
    assert {:error, %Relay.Error{code: :key_not_found}} = KeyPort.read_secret(keys, "absent")
  end

  test "TN-63: a missing or mistyped key is not found", %{keys: keys} do
    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.sign(keys, :es256, "absent", "m")

    assert {:error, %Relay.Error{code: :key_not_found}} = KeyPort.sign(keys, :rs256, "es256", "m")

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.wrap(keys, "es256", "", Redacted.wrap("k"))
  end

  test "TN-26: a wrong PIN keeps the server up and reports the store unavailable", %{
    pkcs11_module: module,
    dir: dir
  } do
    bad_pin = Path.join(dir, "bad-pin")
    File.write!(bad_pin, "0000")
    name = :softhsm_bad_pin

    start_supervised!(
      {KeyPort,
       name: name,
       executable: @executable,
       sha256: sha256(),
       module: module,
       token: @token,
       pin_file: bad_pin,
       min_backoff: 60_000},
      id: :bad_pin
    )

    capture_log(fn ->
      assert {:error, %Relay.Error{code: :key_store_unavailable}} = KeyPort.ping(name)
    end)

    assert Process.alive?(Process.whereis(name))
  end
end
