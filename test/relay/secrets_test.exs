defmodule Relay.SecretsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Redacted
  alias Relay.Secrets

  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)
    System.put_env("SECRETS_TEST_SMTP_PASSWORD", "hunter2-smtp")

    on_exit(fn ->
      Application.put_env(:relay, :keys, previous)
      System.delete_env("SECRETS_TEST_SMTP_PASSWORD")
    end)
  end

  describe "TN-26 secret references" do
    test "TN-26: a reference is ${VAR} or a PKCS#11 URI naming one object" do
      assert Secrets.parse("${SMTP_PASSWORD}") == {:ok, {:env, "SMTP_PASSWORD"}}

      assert Secrets.parse("pkcs11:token=relay;object=smtp%20password") ==
               {:ok, {:pkcs11, "smtp password"}}

      assert Secrets.parse(Relay.Keys.uri("apns/key 1")) == {:ok, {:pkcs11, "apns/key 1"}}

      for ref <- [
            "SMTP_PASSWORD",
            "${smtp}",
            "${A}B",
            "$SMTP",
            "pkcs11:token=relay",
            "pkcs11:object=a;object=b",
            "smtp://user:pass@host",
            "plain-secret"
          ] do
        assert {:error, %Relay.Error{}} = Secrets.parse(ref), ref
      end
    end

    test "TN-26: a PKCS#11 reference that carries a PIN is refused" do
      for ref <- ["pkcs11:object=smtp;pin-value=1234", "pkcs11:object=smtp?pin-source=file:/pin"] do
        assert {:error, %Relay.Error{code: :invalid_key_ref}} = Secrets.parse(ref)
      end
    end

    test "TN-26: ${VAR} resolves from the node environment and a missing variable is an error" do
      assert {:ok, secret} = Secrets.resolve("${SECRETS_TEST_SMTP_PASSWORD}")
      assert Redacted.expose(secret) == "hunter2-smtp"

      assert {:error, %Relay.Error{code: :secret_unavailable}} =
               Secrets.resolve("${SECRETS_TEST_NOT_SET}")
    end

    test "TN-26: a PKCS#11 reference is read from the key store" do
      expect(Relay.KeysMock, :read_secret, fn "smtp" -> {:ok, Redacted.wrap("from-hsm")} end)
      assert {:ok, secret} = Secrets.resolve("pkcs11:object=smtp")
      assert Redacted.expose(secret) == "from-hsm"
    end

    test "INV-51: a resolved secret never shows in inspect, JSON, logs or its fingerprint" do
      {:ok, secret} = Secrets.resolve("${SECRETS_TEST_SMTP_PASSWORD}")

      refute inspect(secret) =~ "hunter2"
      refute Jason.encode!(%{secret: secret}) =~ "hunter2"

      log =
        capture_log(fn ->
          require Logger
          Logger.error("resolved", secret: secret)
        end)

      refute log =~ "hunter2"

      expect(Relay.KeysMock, :hmac_sha256, fn "fingerprint-test", ^secret ->
        {:ok, :crypto.mac(:hmac, :sha256, <<7::256>>, Redacted.expose(secret))}
      end)

      assert {:ok, fingerprint} = Secrets.fingerprint(secret)
      assert fingerprint == :crypto.mac(:hmac, :sha256, <<7::256>>, "hunter2-smtp")
      refute fingerprint =~ "hunter2"
    end

    test "TN-67 (4): the fingerprint is an HMAC inside the key store, never a plain digest" do
      {:ok, secret} = Secrets.resolve("${SECRETS_TEST_SMTP_PASSWORD}")
      error = Relay.Error.new(:key_store_unavailable, "down")
      expect(Relay.KeysMock, :hmac_sha256, fn "fingerprint-test", ^secret -> {:error, error} end)

      assert Secrets.fingerprint(secret) == {:error, error}

      previous = Application.get_env(:relay, Relay.Keys)

      try do
        Application.put_env(:relay, Relay.Keys, kek_label: "kek-test")

        assert {:error, %Relay.Error{code: :key_store_config}} = Secrets.fingerprint(secret)
      after
        Application.put_env(:relay, Relay.Keys, previous)
      end
    end
  end
end
