defmodule Relay.Connectors.ConfigFileTest do
  use ExUnit.Case, async: true

  alias Relay.Config.Error
  alias Relay.Connectors.ConfigFile
  alias Relay.Connectors.Connector
  alias Relay.Connectors.Outbox

  @moduletag :tmp_dir

  @options %{
    "hostname" => "db.example.com",
    "database" => "shop",
    "username" => "relay_reader",
    "password_file" => "/run/secrets/shop_db",
    "table" => "public.relay_outbox"
  }

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "orders",
        "source" => "outbox",
        "access_tenant_id" => "acc_1",
        "access_client_id" => "app_1",
        "options" => @options
      },
      overrides
    )
  end

  defp document(entries), do: Jason.encode!(%{"connectors" => entries})

  describe "T-96 INV-46 connectors from RELAY_CONNECTORS_FILE" do
    test "T-96: without the variable no connector runs" do
      assert ConfigFile.read!(nil) == []
      assert Connector.configured(connectors: ConfigFile.read!(nil)) == []
    end

    test "T-96: the file is read into connector entries that pass the connector rules",
         %{tmp_dir: dir} do
      path = Path.join(dir, "connectors.json")

      ssl = %{"cacertfile" => "/run/secrets/ca.pem", "server_name_indication" => "db"}
      options = Map.merge(@options, %{"port" => 6432, "ssl" => ssl, "poll_ms" => 500})
      File.write!(path, document([entry(%{"concurrency" => 2, "options" => options})]))

      assert [read] = ConfigFile.read!(path)
      assert read[:name] == :orders
      assert read[:source] == :outbox
      assert read[:concurrency] == 2

      assert [%Connector{name: :orders, concurrency: 2, producer: {Outbox, producer}}] =
               Connector.configured(connectors: [read])

      assert producer[:port] == 6432
      assert producer[:poll_ms] == 500
      assert producer[:password_file] == "/run/secrets/shop_db"
      assert producer[:ssl][:verify] == :verify_peer
      assert producer[:ssl][:cacertfile] == ~c"/run/secrets/ca.pem"
      assert producer[:ssl][:server_name_indication] == ~c"db"
    end

    test "T-96: a password is never taken from the file" do
      bad = entry(%{"options" => Map.put(@options, "password", "secret")})

      assert_raise Error, ~r/password_file/, fn -> ConfigFile.parse!(document([bad])) end
    end

    test "INV-46: an unreadable, empty or malformed file stops the node", %{tmp_dir: dir} do
      assert_raise Error, ~r/RELAY_CONNECTORS_FILE/, fn ->
        ConfigFile.read!(Path.join(dir, "missing.json"))
      end

      assert_raise Error, ~r/empty/, fn -> ConfigFile.read!("") end

      for content <- [
            "{",
            "[]",
            ~s({"connectors": {}}),
            ~s({"connectors": [], "pipelines": []})
          ] do
        assert_raise Error, ~r/RELAY_CONNECTORS_FILE/, fn -> ConfigFile.parse!(content) end
      end
    end

    test "INV-46: an invalid connector stops the node" do
      for bad <- [
            entry(%{"retry" => true}),
            entry(%{"name" => "Orders"}),
            entry(%{"name" => 7}),
            entry(%{"source" => "nats"}),
            Map.delete(entry(), "source"),
            entry(%{"options" => []}),
            entry(%{"options" => Map.put(@options, "pool", 3)}),
            entry(%{"options" => Map.put(@options, "ssl", "yes")}),
            entry(%{"options" => Map.put(@options, "ssl", %{"verify" => "verify_none"})}),
            entry(%{"options" => Map.delete(@options, "password_file")}),
            entry(%{"options" => Map.put(@options, "table", "Orders; SELECT 1")}),
            entry(%{"concurrency" => 0}),
            "orders"
          ] do
        assert_raise Error, fn -> ConfigFile.parse!(document([bad])) end
      end

      assert_raise Error, ~r/unique/, fn -> ConfigFile.parse!(document([entry(), entry()])) end
    end

    test "T-95: a Kafka or SQS source needs its package in the release" do
      for source <- ["kafka", "sqs"] do
        bad = entry(%{"source" => source, "options" => %{"concurrency" => 1}})
        assert_raise Error, ~r/broadway_#{source}/, fn -> ConfigFile.parse!(document([bad])) end
      end
    end
  end
end
