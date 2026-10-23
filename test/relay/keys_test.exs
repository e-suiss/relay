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

  test "TN-66: blind index HMACs are computed by the key store from a redacted message" do
    message = Redacted.wrap("ada@example.com")
    expect(Relay.KeysMock, :hmac_sha256, fn "bidx", ^message -> {:ok, <<1::256>>} end)
    expect(Relay.KeysMock, :read_secret, fn "smtp" -> {:ok, Redacted.wrap("pw")} end)

    assert Keys.hmac_sha256("bidx", message) == {:ok, <<1::256>>}
    assert {:ok, secret} = Keys.read_secret("smtp")
    assert Redacted.expose(secret) == "pw"
  end

  test "TN-67 (1): keys are generated inside the key store under a label and an object identifier" do
    expect(Relay.KeysMock, :generate_key, fn :hmac_sha256, "bidx-t1", <<1::128>> -> :ok end)
    assert Keys.generate_key(:hmac_sha256, "bidx-t1", <<1::128>>) == :ok

    for args <- [[:rsa, "k", "i"], [:aes_256, "", "i"], [:aes_256, "k", ""]] do
      assert_raise FunctionClauseError, fn -> apply(Keys, :generate_key, args) end
    end
  end

  test "TN-67 (1): the region KEK and fingerprint key labels come from the installation configuration" do
    previous = Application.get_env(:relay, Relay.Keys)

    try do
      Application.put_env(:relay, Relay.Keys, kek_label: "kek-tr", fingerprint_label: "fp-tr")
      assert Keys.kek_label() == {:ok, "kek-tr"}
      assert Keys.fingerprint_label() == {:ok, "fp-tr"}

      Application.delete_env(:relay, Relay.Keys)
      assert {:error, %Error{code: :key_store_config}} = Keys.kek_label()
      assert {:error, %Error{code: :key_store_config}} = Keys.fingerprint_label()
    after
      Application.put_env(:relay, Relay.Keys, previous)
    end
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
