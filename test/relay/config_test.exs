defmodule Relay.ConfigTest do
  use ExUnit.Case, async: true

  alias Relay.Config
  alias Relay.Config.Error

  @valid [ecto_repos: [Relay.Repo], roles: [:api, :worker, :socket], clock: Relay.Clock.System]

  describe "INV-46 strict configuration" do
    test "INV-46: a valid configuration passes" do
      assert :ok = Config.validate!(@valid, %{"RELAY_ROLES" => "api"})
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
