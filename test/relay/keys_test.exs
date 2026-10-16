defmodule Relay.KeysTest do
  use ExUnit.Case, async: false

  import Mox

  alias Relay.Error
  alias Relay.Keys
  alias Relay.Redacted

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)
    on_exit(fn -> Application.put_env(:relay, :keys, previous) end)
  end

  test "TN-63: the key store program is supervised only where it is configured" do
    previous = Application.get_env(:relay, Relay.Keys.Port)

    try do
      Application.delete_env(:relay, Relay.Keys.Port)
      assert Keys.children() == []

      Application.put_env(:relay, Relay.Keys.Port,
        module: "/usr/lib/pkcs11/provider.so",
        token: "relay",
        pin_file: "/run/secrets/relay-pkcs11/pin"
      )

      assert [{Relay.Keys.Port, opts}] = Keys.children()

      assert Enum.sort(opts) == [
               module: "/usr/lib/pkcs11/provider.so",
               pin_file: "/run/secrets/relay-pkcs11/pin",
               token: "relay"
             ]
    after
      if previous,
        do: Application.put_env(:relay, Relay.Keys.Port, previous),
        else: Application.delete_env(:relay, Relay.Keys.Port)
    end
  end

  test "TN-63: calls go to the configured key store" do
    expect(Relay.KeysMock, :ping, fn -> :ok end)
    expect(Relay.KeysMock, :sign, fn :es256, "apns", "jwt" -> {:ok, <<0::512>>} end)
    expect(Relay.KeysMock, :public_key, fn :rs256, "fcm" -> {:ok, {"n", "e"}} end)

    assert Keys.ping() == :ok
    assert Keys.sign(:es256, "apns", "jwt") == {:ok, <<0::512>>}
    assert Keys.public_key(:rs256, "fcm") == {:ok, {"n", "e"}}
  end

  test "TN-27: data keys travel redacted in both directions" do
    key = Redacted.wrap(<<7::256>>)
    expect(Relay.KeysMock, :wrap, fn "kek", "tenant", ^key -> {:ok, "wrapped"} end)
    expect(Relay.KeysMock, :unwrap, fn "kek", "tenant", "wrapped" -> {:ok, key} end)

    assert Keys.wrap("kek", "tenant", key) == {:ok, "wrapped"}
    assert {:ok, unwrapped} = Keys.unwrap("kek", "tenant", "wrapped")
    assert Redacted.expose(unwrapped) == <<7::256>>
  end

  test "TN-63: errors are typed" do
    error = Error.new(:key_not_found, "key store: key not found")
    expect(Relay.KeysMock, :sign, fn :ed25519, "checkpoint", "note" -> {:error, error} end)
    assert Keys.sign(:ed25519, "checkpoint", "note") == {:error, error}
  end

  test "TN-35: unknown algorithms and empty labels are refused before the key store" do
    calls = [
      {:sign, [:hs256, "apns", "jwt"]},
      {:sign, [:es256, "", "jwt"]},
      {:public_key, [:es384, "vapid"]},
      {:unwrap, ["", "aad", "wrapped"]}
    ]

    for {fun, args} <- calls do
      assert_raise FunctionClauseError, fn -> apply(Keys, fun, args) end
    end
  end
end
