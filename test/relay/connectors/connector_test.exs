defmodule Relay.Connectors.ConnectorTest do
  use ExUnit.Case, async: true

  alias Relay.Config.Error
  alias Relay.Connectors.Connector
  alias Relay.Connectors.Outbox

  @options [
    hostname: "db.example.com",
    database: "shop",
    username: "relay_reader",
    password_file: "/run/secrets/shop_db",
    table: "public.relay_outbox"
  ]

  defp entry(overrides \\ []) do
    Keyword.merge(
      [
        name: :orders,
        source: :outbox,
        access_tenant_id: "acc_1",
        access_client_id: "app_1",
        options: @options
      ],
      overrides
    )
  end

  describe "T-41 T-7 INV-46 connector configuration" do
    test "T-7: without a configured connector nothing starts" do
      assert Connector.configured([]) == []
      assert Relay.Connectors.children() == []
    end

    test "T-41: an outbox connector is read with its defaults" do
      connector = Connector.parse!(entry())
      assert %Connector{name: :orders, source: :outbox, concurrency: 4} = connector

      assert {Outbox, options} = connector.producer
      assert options[:port] == 5432
      assert options[:ssl] == false
      assert options[:poll_ms] == 1000
      assert options[:batch_size] == 100
      assert options[:lease_s] == 60

      assert Connector.process_name(connector) ==
               Module.concat(Relay.Connectors.Pipeline, "orders")
    end

    test "T-7: a Kafka or SQS source needs its package in the release" do
      assert_raise Error, ~r/broadway_kafka/, fn ->
        Connector.parse!(entry(source: :kafka, options: [hosts: [localhost: 9092]]))
      end

      assert_raise Error, ~r/broadway_sqs/, fn ->
        Connector.parse!(entry(source: :sqs, options: [queue_url: "https://sqs.example"]))
      end
    end

    test "INV-46: an invalid entry or a repeated name stops startup" do
      for bad <- [
            entry(source: :nats),
            entry(name: "orders"),
            entry(name: :Orders),
            entry(access_client_id: ""),
            entry(concurrency: 0),
            entry(retry: true),
            entry(options: Keyword.put(@options, :table, "Orders; SELECT 1")),
            entry(options: Keyword.delete(@options, :password_file)),
            entry(options: Keyword.put(@options, :password, "secret")),
            entry(options: Keyword.put(@options, :ssl, verify: :verify_none)),
            entry(options: Keyword.put(@options, :batch_size, 10_000))
          ] do
        assert_raise Error, fn -> Connector.parse!(bad) end
      end

      assert_raise Error, ~r/unique/, fn ->
        Connector.configured(connectors: [entry(), entry()])
      end

      assert_raise Error, fn -> Connector.configured(pipelines: []) end
    end
  end
end
