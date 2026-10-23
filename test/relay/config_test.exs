defmodule Relay.ConfigTest do
  use ExUnit.Case, async: true

  alias Relay.Config
  alias Relay.Config.Error

  @valid [ecto_repos: [Relay.Repo], roles: [:api, :worker, :socket], clock: Relay.Clock.System]

  describe "INV-46 strict configuration" do
    test "INV-46: a valid configuration passes" do
      assert :ok = Config.validate!(@valid, %{"RELAY_ROLES" => "api"})
    end

    test "TN-63: the key store implementation is a known key" do
      assert :keys in Config.known_app_keys()
      assert :ok = Config.validate!(Keyword.put(@valid, :keys, Relay.Keys.Port), %{})
    end

    test "TN-63: the key store program takes only its module, token and PIN file" do
      port = [module: "/usr/lib/provider.so", token: "relay", pin_file: "/run/pin"]
      assert Relay.Keys.Port in Config.known_app_keys()
      assert :ok = Config.validate!(Keyword.put(@valid, Relay.Keys.Port, port), %{})

      for bad <- [
            Keyword.put(port, :sha256, String.duplicate("0", 64)),
            Keyword.put(port, :executable, "/tmp/pkcs11_port"),
            Keyword.delete(port, :pin_file),
            Keyword.put(port, :token, nil),
            :enabled
          ] do
        assert_raise Error, ~r/Relay.Keys.Port configuration/, fn ->
          Config.validate!(Keyword.put(@valid, Relay.Keys.Port, bad), %{})
        end
      end
    end

    test "TN-63: production reads the key store settings from the environment" do
      runtime = File.read!("config/runtime.exs")

      for name <- ["PKCS11_MODULE", "PKCS11_TOKEN", "PKCS11_PIN_FILE"] do
        assert runtime =~ ~s[Relay.Config.Env.fetch!("#{name}")]
      end

      refute runtime =~ ~r/Relay\.Config\.Env\.file!\("PKCS11_PIN_FILE"\)/
    end

    test "TN-67 (1): the region KEK and the fingerprint key labels are installation configuration" do
      labels = [kek_label: "kek-tr-1", fingerprint_label: "fingerprint-tr-1"]
      assert Relay.Keys in Config.known_app_keys()
      assert :ok = Config.validate!(Keyword.put(@valid, Relay.Keys, labels), %{})

      for bad <- [
            Keyword.delete(labels, :kek_label),
            Keyword.put(labels, :fingerprint_label, ""),
            Keyword.put(labels, :blind_index_label, "bidx"),
            :kek
          ] do
        assert_raise Error, ~r/Relay.Keys configuration/, fn ->
          Config.validate!(Keyword.put(@valid, Relay.Keys, bad), %{})
        end
      end

      runtime = File.read!("config/runtime.exs")
      assert runtime =~ ~s[kek_label: Relay.Config.Env.fetch!("KEY_STORE_KEK_LABEL")]

      assert runtime =~
               ~s[fingerprint_label: Relay.Config.Env.fetch!("KEY_STORE_FINGERPRINT_LABEL")]

      env = File.read!("deploy/helm/relay/templates/_env.tpl")
      assert env =~ ~s[required "keyStore.kekLabel is required" .Values.keyStore.kekLabel]

      assert env =~
               ~s[required "keyStore.fingerprintLabel is required" .Values.keyStore.fingerprintLabel]
    end

    test "INV-46: an unknown configuration key stops startup" do
      assert_raise Error, ~r/unknown configuration keys.*:retry_forever/, fn ->
        Config.validate!(Keyword.put(@valid, :retry_forever, true), %{})
      end
    end

    test "INV-46: an unknown role stops startup" do
      assert_raise Error, ~r/unknown roles: \[:admin\]/, fn ->
        Config.validate!(Keyword.put(@valid, :roles, [:api, :admin]), %{})
      end
    end

    test "INV-46: an empty or duplicate role list stops startup" do
      assert_raise Error, fn -> Config.validate!(Keyword.put(@valid, :roles, []), %{}) end

      assert_raise Error, fn ->
        Config.validate!(Keyword.put(@valid, :roles, [:api, :api]), %{})
      end
    end

    test "INV-46: an unknown RELAY_ environment variable stops startup" do
      assert_raise Error, ~r/RELAY_DEV_MODE/, fn ->
        Config.validate!(@valid, %{"RELAY_DEV_MODE" => "1"})
      end
    end
  end

  describe "T-7 platform configuration" do
    test "T-7: Valkey, signal and queue configuration keys are known" do
      for key <- [Relay.Platform.Valkey, Relay.Platform.Signal, Oban] do
        assert key in Config.known_app_keys()
      end

      assert :ok =
               @valid
               |> Keyword.put(Relay.Platform.Valkey, adapter: Relay.Platform.Valkey.Redix)
               |> Keyword.put(Relay.Platform.Signal, poll_interval_ms: 1_000)
               |> Keyword.put(Oban, repo: Relay.Repo)
               |> Config.validate!(%{})
    end

    test "T-7: the running configuration passes validation" do
      assert :ok = Config.validate!(Application.get_all_env(:relay), %{})
    end
  end

  describe "TN-8 no weakening flags" do
    test "TN-8: keys that would disable security or compliance checks are unknown" do
      for key <- [:disable_signature_verification, :disable_rls, :dev_mode, :skip_consent_check] do
        refute key in Config.known_app_keys()
        assert_raise Error, fn -> Config.validate!(Keyword.put(@valid, key, true), %{}) end
      end
    end
  end

  describe "OP-70 independent audit target" do
    @s3 [
      endpoint: "https://s3.eu-central-1.amazonaws.com",
      bucket: "relay-audit",
      region: "eu-central-1",
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: Relay.Redacted.wrap("secret"),
      prefix: ""
    ]
    @audit [log_host: "relay.example", checkpoint_key: "audit-checkpoint"]

    defp audit(publishers),
      do: Keyword.put(@valid, Relay.Audit, Keyword.put(@audit, :publishers, publishers))

    test "OP-70: a production node does not start without an independent target" do
      for config <- [@valid, audit([])] do
        assert_raise Error, ~r/Relay.Audit|independent of Relay/, fn ->
          Config.validate!(config, %{}, production?: true)
        end
      end

      secret = {Relay.Config.SecretFiles, :fetch!, [:audit_s3]}
      s3 = Keyword.put(@s3, :secret_access_key, secret)

      assert :ok =
               Config.validate!(
                 audit([{"worm_store", Relay.Audit.Checkpointer.Publisher.S3, s3}]),
                 %{},
                 production?: true
               )
    end

    test "OP-70: the test plane and local development may run with a local target or none" do
      assert :ok = Config.validate!(audit([]), %{}, production?: false)
      assert :ok = Config.validate!(@valid, %{}, production?: false)

      [{"worm_store", Relay.Audit.Checkpointer.Publisher.S3, local}] =
        "config/dev.exs"
        |> Elixir.Config.Reader.read!(env: :dev)
        |> get_in([:relay, Relay.Audit, :publishers])

      assert local[:endpoint] == "http://localhost:9000"
    end

    test "OP-70: publisher options are checked when the node starts" do
      s3 = Relay.Audit.Checkpointer.Publisher.S3

      for {bad, message} <- [
            {Keyword.delete(@s3, :bucket), ~r/missing options/},
            {Keyword.put(@s3, :verify, false), ~r/unknown options/},
            {Keyword.put(@s3, :endpoint, "ftp://store"), ~r/endpoint/},
            {Keyword.put(@s3, :prefix, "audit"), ~r/prefix/},
            {Keyword.put(@s3, :secret_access_key, ""), ~r/secret_access_key/}
          ] do
        assert_raise Error, message, fn ->
          Config.validate!(audit([{"worm_store", s3, bad}]), %{}, production?: true)
        end
      end

      assert_raise Error, ~r/unknown audit publication target/, fn ->
        Config.validate!(audit([{"elsewhere", s3, @s3}]), %{}, production?: false)
      end

      assert_raise Error, ~r/not a publisher/, fn ->
        Config.validate!(audit([{"siem", Relay.Config, []}]), %{}, production?: false)
      end

      assert_raise Error, ~r/duplicate/, fn ->
        Config.validate!(audit([{"worm_store", s3, @s3}, {"worm_store", s3, @s3}]), %{})
      end
    end

    test "OP-70: the object lock document check needs object lock and a default retention" do
      s3 = Relay.Audit.Checkpointer.Publisher.S3

      assert s3.locked?(
               "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention><Mode>COMPLIANCE</Mode><Years>10</Years></DefaultRetention></Rule></ObjectLockConfiguration>"
             )

      refute s3.locked?(
               "<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled></ObjectLockConfiguration>"
             )

      refute s3.locked?("<ObjectLockConfiguration></ObjectLockConfiguration>")
    end
  end

  describe "WF-47 TP-43 pinned time zone data" do
    test "TP-43: tzdata never updates itself at runtime" do
      assert Application.fetch_env!(:tzdata, :autoupdate) == :disabled
    end
  end

  describe "runtime environment readers" do
    alias Relay.Config.Env

    test "TN-26: a password inside the database URL is refused" do
      System.put_env("TEST_DB_URL", "ecto://relay:secret@db/relay")

      assert_raise Error, ~r/must not contain a password/, fn ->
        Env.database_url!("TEST_DB_URL")
      end

      System.put_env("TEST_DB_URL", "ecto://relay@db/relay")
      assert Env.database_url!("TEST_DB_URL") == "ecto://relay@db/relay"
    after
      System.delete_env("TEST_DB_URL")
    end

    test "TN-26: a Valkey URL must be redis:// or rediss:// and carry no password" do
      System.put_env("TEST_VALKEY_URL", "redis://valkey:6379")
      assert Env.valkey_url!("TEST_VALKEY_URL") == "redis://valkey:6379"

      System.put_env("TEST_VALKEY_URL", "rediss://default@valkey:6380")
      assert Env.valkey_url!("TEST_VALKEY_URL") == "rediss://default@valkey:6380"

      System.put_env("TEST_VALKEY_URL", "redis://default:secret@valkey:6379")

      assert_raise Error, ~r/must not contain a password/, fn ->
        Env.valkey_url!("TEST_VALKEY_URL")
      end

      for url <- ["http://valkey:6379", "valkey:6379", "redis://"] do
        System.put_env("TEST_VALKEY_URL", url)
        assert_raise Error, ~r/redis:\/\//, fn -> Env.valkey_url!("TEST_VALKEY_URL") end
      end
    after
      System.delete_env("TEST_VALKEY_URL")
    end

    test "OP-70: production reads the independent audit target from the environment" do
      runtime = File.read!("config/runtime.exs")

      for name <- [
            "AUDIT_S3_ENDPOINT",
            "AUDIT_S3_BUCKET",
            "AUDIT_S3_REGION",
            "AUDIT_S3_ACCESS_KEY_ID"
          ],
          do: assert(runtime =~ ~s[Relay.Config.Env.fetch!("#{name}")])

      assert runtime =~ ~s[Relay.Config.Env.fetch!("AUDIT_S3_SECRET_ACCESS_KEY_FILE")]
      assert runtime =~ "Relay.Audit.Checkpointer.Publisher.S3"
    end

    test "INV-46: missing values have no default" do
      assert_raise Error, ~r/is required/, fn -> Env.fetch!("TEST_MISSING_VALUE") end
    end

    test "T-3: roles parse from a comma-separated list and reject unknown roles" do
      System.put_env("TEST_ROLES", "api, worker")
      assert Env.roles!("TEST_ROLES") == [:api, :worker]
      System.put_env("TEST_ROLES", "api,admin")
      assert_raise Error, fn -> Env.roles!("TEST_ROLES") end
    after
      System.delete_env("TEST_ROLES")
    end
  end
end
