defmodule Relay.Webhooks.Destination.KindsTest do
  use ExUnit.Case, async: true

  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Destination.Kinds

  @kinds ~w(aws_eventbridge aws_sns aws_sqs azure_event_grid azure_service_bus gcp_pubsub https
            kafka nats_jetstream rabbitmq s3)

  describe "WH-17 destination set" do
    test "WH-17: every destination kind has a module behind the common port" do
      assert Kinds.all() == @kinds

      for kind <- @kinds do
        assert {:ok, module} = Kinds.module(kind)
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :deliver, 3)
        behaviours = Keyword.get_values(module.module_info(:attributes), :behaviour)
        assert Destination in List.flatten(behaviours)
      end
    end

    test "WH-17: a name that is not a destination kind has no module" do
      assert Kinds.module("smtp") == :error
      assert Kinds.module(nil) == :error
      assert Kinds.module(:kafka) == :error
    end
  end
end
