defmodule Relay.DevKeyStoreTest do
  use ExUnit.Case, async: true

  describe "TN-66 local key store" do
    test "TN-66: the development node runs the key store on the SoftHSM token" do
      dev = Config.Reader.read!("config/dev.exs", env: :dev)
      opts = get_in(dev, [:relay, Relay.Keys.Port])

      assert opts[:token] == "relay-dev"
      assert opts[:module] =~ "softhsm2"
      assert opts[:pin_file] == Path.expand("deploy/softhsm/pin")
      assert Keyword.keys(opts) -- Relay.Keys.port_config_keys() == []
    end

    test "TN-66: just dev initialises the token, creates the keys, installs the program and starts the node" do
      justfile = File.read!("justfile")

      assert [_, deps] = Regex.run(~r/^dev: (.+)$/m, justfile)
      assert "hsm-keys" in String.split(deps)
      assert "port" in String.split(deps)
      assert justfile =~ ~r/^hsm-keys: hsm$/m
      assert justfile =~ "iex -S mix phx.server"
      assert justfile =~ ~r/^export SOFTHSM2_CONF := /m
    end

    test "TN-65 (7): the development program is installed with the checksum the build embeds" do
      justfile = File.read!("justfile")

      assert justfile =~
               "cp native/pkcs11_port/target/release/pkcs11_port priv/native/pkcs11_port"

      assert justfile =~
               "cp native/pkcs11_port/target/release/pkcs11_port.sha256 priv/native/pkcs11_port.sha256"

      assert File.read!("lib/relay/keys/port.ex") =~ ~s(@program "priv/native/pkcs11_port")
    end
  end
end

defmodule Relay.HsmKeysTest do
  use ExUnit.Case, async: false

  alias Relay.Keys.Port, as: KeyPort
  alias Relay.Redacted

  @moduletag :integration

  @pin "1234"
  @token "relay-hsm-keys"
  @script Path.expand("../../deploy/hsm-keys.sh", __DIR__)
  @executable Path.expand("../../native/pkcs11_port/target/release/pkcs11_port", __DIR__)
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

    dir = Path.join(System.tmp_dir!(), "relay-hsm-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "tokens"))
    conf = Path.join(dir, "softhsm2.conf")
    File.write!(conf, "directories.tokendir = #{dir}/tokens\nobjectstore.backend = file\n")
    pin_file = Path.join(dir, "pin")
    File.write!(pin_file, @pin)

    env = [
      {"SOFTHSM2_CONF", conf},
      {"PKCS11_MODULE", module},
      {"PKCS11_TOKEN", @token},
      {"PKCS11_PIN_FILE", pin_file},
      {"KEY_STORE_KEK_LABEL", "kek-test"},
      {"KEY_STORE_FINGERPRINT_LABEL", "fingerprint-test"},
      {"KEY_STORE_CURSOR_LABEL", "cursor-test"},
      {"KEY_STORE_BLIND_INDEX_LABEL", "bidx-test"}
    ]

    {out, 0} =
      System.cmd(
        "softhsm2-util",
        ~w(--init-token --free --label #{@token} --pin #{@pin} --so-pin 12345678),
        env: env,
        stderr_to_stdout: true
      )

    assert out =~ "initialized"

    previous = System.get_env("SOFTHSM2_CONF")
    System.put_env("SOFTHSM2_CONF", conf)

    on_exit(fn ->
      if previous,
        do: System.put_env("SOFTHSM2_CONF", previous),
        else: System.delete_env("SOFTHSM2_CONF")

      File.rm_rf!(dir)
    end)

    %{env: env, pkcs11_module: module, pin_file: pin_file}
  end

  defp script(env), do: System.cmd(@script, [], env: env, stderr_to_stdout: true)

  defp objects(%{env: env, pkcs11_module: module}, type) do
    {out, 0} =
      System.cmd(
        "pkcs11-tool",
        ~w(--module #{module} --token-label #{@token} --login --pin #{@pin} --list-objects --type #{type}),
        env: env,
        stderr_to_stdout: true
      )

    out
  end

  test "TN-65 (2): without a blind index label the script creates no installation-wide blind index key",
       ctx do
    env =
      ctx.env
      |> List.keydelete("KEY_STORE_BLIND_INDEX_LABEL", 0)
      |> List.keystore("KEY_STORE_KEK_LABEL", 0, {"KEY_STORE_KEK_LABEL", "kek-only"})

    assert {out, 0} = script([{"KEY_STORE_BLIND_INDEX_LABEL", nil} | env])
    assert out =~ "hsm-keys: kek-only created"
    refute out =~ "bidx"
  end

  test "OP-63: the script creates the checkpoint key, the KEK and the blind index key once",
       ctx do
    assert {out, 0} = script(ctx.env)
    assert out =~ ~r/hsm-keys: audit-checkpoint (created|exists)/
    assert out =~ "hsm-keys: kek-test created"
    assert out =~ "hsm-keys: bidx-test created"
    assert out =~ ~r/hsm-keys: fingerprint-test (created|exists)/

    assert {again, 0} = script(ctx.env)
    assert again =~ "hsm-keys: audit-checkpoint exists"
    assert again =~ "hsm-keys: kek-test exists"
    assert again =~ "hsm-keys: bidx-test exists"
    assert again =~ "hsm-keys: fingerprint-test exists"

    assert length(Regex.scan(~r/label: *audit-checkpoint$/m, objects(ctx, "privkey"))) == 1

    secrets = objects(ctx, "secrkey")
    assert length(Regex.scan(~r/label: *kek-test$/m, secrets)) == 1
    assert [bidx] = Regex.run(~r/label: *bidx-test$.*?(?=^\S|\z)/ms, secrets)
    assert bidx =~ ~r/Usage:.*\bsign\b/
    assert [fingerprint] = Regex.run(~r/label: *fingerprint-test$.*?(?=^\S|\z)/ms, secrets)
    assert fingerprint =~ ~r/Usage:.*\bsign\b/

    name = {:global, make_ref()}
    sha256 = (@executable <> ".sha256") |> File.read!() |> String.split() |> hd()

    start_supervised!(
      {KeyPort,
       name: name,
       executable: @executable,
       sha256: sha256,
       module: ctx.pkcs11_module,
       token: @token,
       pin_file: ctx.pin_file}
    )

    assert {:ok, <<_::binary-size(32)>> = public} =
             KeyPort.public_key(name, :ed25519, "audit-checkpoint")

    assert {:ok, signature} = KeyPort.sign(name, :ed25519, "audit-checkpoint", "note")
    assert :crypto.verify(:eddsa, :none, "note", signature, [public, :ed25519])

    data_key = :crypto.strong_rand_bytes(32)
    assert {:ok, wrapped} = KeyPort.wrap(name, "kek-test", "tenant", Redacted.wrap(data_key))
    assert {:ok, unwrapped} = KeyPort.unwrap(name, "kek-test", "tenant", wrapped)
    assert Redacted.expose(unwrapped) == data_key

    assert {:ok, <<_::256>>} =
             KeyPort.hmac_sha256(name, "fingerprint-test", Redacted.wrap("secret"))
  end

  test "TN-67 (4): the script requires the secret fingerprint key label", ctx do
    env =
      List.keystore(
        ctx.env,
        "KEY_STORE_FINGERPRINT_LABEL",
        0,
        {"KEY_STORE_FINGERPRINT_LABEL", nil}
      )

    assert {out, status} = script(env)
    assert status != 0
    assert out =~ "KEY_STORE_FINGERPRINT_LABEL is required"
  end
end
