defmodule Relay.RegionConfigTest do
  use ExUnit.Case, async: true

  alias Relay.Config
  alias Relay.Datasets

  describe "OP-90 region configuration" do
    test "OP-90: a node whose RELAY_REGION is not the installation region does not start" do
      assert :ok = Datasets.region_check("tr", fn -> "tr" end)

      assert {:error, %Relay.Error{code: :region_mismatch, details: details}} =
               Datasets.region_check("eu", fn -> "tr" end)

      assert details == %{configured: "eu", installation: "tr"}
    end

    test "OP-90: a node without a configured region (development and test) checks nothing" do
      assert :ok = Datasets.region_check(nil, fn -> flunk("the installation was read") end)
    end

    test "OP-90, OP-75: production reads RELAY_REGION and RELAY_EGRESS_IPS, and the chart sets them" do
      assert "RELAY_REGION" in Config.known_os_env_keys()
      assert "RELAY_EGRESS_IPS" in Config.known_os_env_keys()
      runtime = File.read!("config/runtime.exs")
      assert runtime =~ ~s[configured: Relay.Config.Env.fetch!("RELAY_REGION")]
      assert runtime =~ ~s[egress_ips: Relay.Config.Env.cidrs!("RELAY_EGRESS_IPS")]
      env = File.read!("deploy/helm/relay/templates/_env.tpl")
      assert env =~ "- name: RELAY_REGION\n"
      assert env =~ "- name: RELAY_EGRESS_IPS\n"
    end

    test "OP-88: production reads the node count and the pooler, and only known poolers" do
      assert "RELAY_NODE_COUNT" in Config.known_os_env_keys()
      assert "RELAY_DATABASE_POOLER" in Config.known_os_env_keys()
      System.put_env("TEST_POOLER", "pgbouncer")
      assert Config.Env.choice!("TEST_POOLER", ["none", "pgbouncer"]) == "pgbouncer"
      System.put_env("TEST_POOLER", "pgpool")

      assert_raise Config.Error, ~r/TEST_POOLER must be one of: none, pgbouncer/, fn ->
        Config.Env.choice!("TEST_POOLER", ["none", "pgbouncer"])
      end
    after
      System.delete_env("TEST_POOLER")
    end
  end
end
