defmodule Relay.Keys.PortTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Relay.Keys.Port, as: KeyPort
  alias Relay.Redacted

  @fake Path.expand("../../support/fake_pkcs11_port.escript", __DIR__)

  setup %{tmp_dir: dir} do
    exe = Path.join(dir, "pkcs11_port")
    File.write!(exe, "#!/bin/sh\nERL_CRASH_DUMP_SECONDS=0 exec escript #{@fake} \"$@\"\n")
    File.chmod!(exe, 0o755)
    File.write!(exe <> ".sha256", checksum(exe) <> "  pkcs11_port\n")
    %{exe: exe}
  end

  defp checksum(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp start(exe, mode, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          executable: exe,
          module: mode,
          token: "relay-test",
          pin_file: "/nonexistent/pin",
          timeout: 10_000,
          min_backoff: 10,
          max_backoff: 50
        ],
        opts
      )

    {name, opts} = Keyword.pop(opts, :name)
    name = name || {:global, make_ref()}
    start_supervised!({KeyPort, [{:name, name} | opts]})
    name
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      :ok ->
        :ok

      other when tries == 0 ->
        other

      _ ->
        receive after: (30 -> eventually(fun, tries - 1))
    end
  end

  @moduletag :tmp_dir

  test "TN-63: requests and responses travel over the port", %{exe: exe} do
    keys = start(exe, "ok")
    assert KeyPort.ping(keys) == :ok
    assert KeyPort.sign(keys, :es256, "apns", "header.claims") == {:ok, "header.claims"}
    assert KeyPort.public_key(keys, :rs256, "fcm") == {:ok, {"n", "e"}}

    assert {:error, %Relay.Error{code: :key_not_found}} =
             KeyPort.public_key(keys, :es256, "vapid")
  end

  test "TN-27: data keys are sent from a closure and come back redacted", %{exe: exe} do
    keys = start(exe, "ok")
    assert {:ok, wrapped} = KeyPort.wrap(keys, "kek", "tenant", Redacted.wrap("dek"))
    assert wrapped == "wdek"
    assert {:ok, key} = KeyPort.unwrap(keys, "kek", "tenant", wrapped)
    assert Redacted.expose(key) == "dek"

    assert {:error, %Relay.Error{code: :key_integrity}} =
             KeyPort.unwrap(keys, "kek", "tenant", "tampered")
  end

  test "TN-63: a crashing program fails the request and is reopened", %{exe: exe} do
    keys = start(exe, "crash")
    pid = GenServer.whereis(keys)

    log =
      capture_log(fn ->
        assert {:error, %Relay.Error{code: :key_store_unavailable}} =
                 KeyPort.sign(keys, :es256, "apns", "m")

        assert eventually(fn -> KeyPort.ping(keys) end) == :ok
      end)

    assert log =~ "key store program exited"
    assert GenServer.whereis(keys) == pid
  end

  test "TN-63: a hung request times out and the program is restarted", %{exe: exe} do
    keys = start(exe, "hang", timeout: 300)

    capture_log(fn ->
      assert {:error, %Relay.Error{code: :key_store_timeout}} =
               KeyPort.sign(keys, :es256, "apns", "m")

      assert eventually(fn -> KeyPort.ping(keys) end) == :ok
    end)
  end

  test "TN-63: a response for an unknown request is dropped", %{exe: exe} do
    keys = start(exe, "stale")
    assert KeyPort.sign(keys, :es256, "apns", "m") == {:ok, "m"}
    assert KeyPort.ping(keys) == :ok
  end

  test "TN-63: a malformed response restarts the program", %{exe: exe} do
    keys = start(exe, "garbage")

    assert {:error, %Relay.Error{code: :key_store_protocol}} =
             KeyPort.sign(keys, :es256, "apns", "m")

    assert eventually(fn -> KeyPort.ping(keys) end) == :ok
  end

  test "T-53: a program whose checksum does not match is never started", %{exe: exe} do
    File.write!(exe <> ".sha256", String.duplicate("0", 64) <> "  pkcs11_port\n")

    log =
      capture_log(fn ->
        keys = start(exe, "ok")

        assert {:error, %Relay.Error{code: :key_store_integrity}} = KeyPort.ping(keys)
      end)

    assert log =~ "failed verification"
  end

  test "T-62: a program without a checksum file is never started", %{exe: exe} do
    File.rm!(exe <> ".sha256")

    capture_log(fn ->
      keys = start(exe, "ok")
      assert {:error, %Relay.Error{code: :key_store_integrity}} = KeyPort.ping(keys)
    end)
  end

  test "TN-63: a call to a server that is not running is a typed error" do
    assert {:error, %Relay.Error{code: :key_store_unavailable}} =
             KeyPort.ping(:keys_not_started)
  end

  test "TN-26: the PIN reaches the program only as a file path", %{exe: exe} do
    keys = start(exe, "ok", pin_file: "/run/secrets/pin")
    %{args: args} = :sys.get_state(keys)
    assert args == ["--module", "ok", "--token", "relay-test", "--pin-file", "/run/secrets/pin"]
  end
end
