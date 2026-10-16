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
